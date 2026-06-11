defmodule SymphonyElixir.RepositoryRoutes do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Adapter

  @cache_key {__MODULE__, :dynamic_routes}
  @github_repo_url_regex ~r/https:\/\/(?:www\.)?github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:\.git)?(?:[\/?#][^\s<)]*)?/i

  @spec effective_project_routes(Config.Schema.t()) :: map()
  def effective_project_routes(settings) do
    static_routes = static_project_routes(settings)

    case dynamic_project_routes(settings) do
      {:ok, dynamic_routes} -> Map.merge(dynamic_routes, static_routes)
      {:error, _reason} -> static_routes
    end
  end

  @spec configured_repository_slugs(Config.Schema.t()) :: [String.t()]
  def configured_repository_slugs(settings) do
    project_route_repos =
      settings
      |> effective_project_routes()
      |> Map.keys()

    [settings.repository.default | project_route_repos]
    |> Enum.map(&canonical_repository_slug/1)
    |> Enum.filter(&valid_repo_slug?/1)
    |> Enum.uniq()
  end

  @spec project_aliases(Config.Schema.t(), String.t()) :: [String.t()]
  def project_aliases(settings, repo) do
    route_aliases =
      settings
      |> effective_project_routes()
      |> project_route_aliases(repo)

    (route_aliases ++ [repo_name(repo)])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec project_route_aliases(map(), String.t()) :: [String.t()]
  def project_route_aliases(project_routes, repo_slug) when is_map(project_routes) do
    canonical_repo_token = canonical_route_repo_token(repo_slug)

    project_routes
    |> Enum.find_value([], fn {raw_repo, aliases} ->
      if canonical_route_repo_token(raw_repo) == canonical_repo_token do
        List.wrap(aliases)
      end
    end)
  end

  def project_route_aliases(_project_routes, _repo_slug), do: []

  @spec route_token(term()) :: String.t()
  def route_token(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  def route_token(_value), do: ""

  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec dynamic_project_routes_for_test(Config.Schema.t(), [map()]) :: {:ok, map()}
  def dynamic_project_routes_for_test(settings, projects) when is_list(projects) do
    settings
    |> allowed_owners()
    |> discover_project_routes(projects)
    |> then(fn {routes, _rejections} -> {:ok, routes} end)
  end

  defp dynamic_project_routes(settings) do
    owners = allowed_owners(settings)

    cond do
      MapSet.size(owners) == 0 ->
        {:ok, %{}}

      not linear_project_discovery_configured?(settings) ->
        {:ok, %{}}

      true ->
        cached_dynamic_project_routes(settings, owners)
    end
  end

  defp cached_dynamic_project_routes(settings, owners) do
    now_ms = System.monotonic_time(:millisecond)
    cache = cached_value()

    if cache_valid?(cache, settings, now_ms) do
      {:ok, cache.routes}
    else
      refresh_dynamic_project_routes(settings, owners, now_ms, cache)
    end
  end

  defp refresh_dynamic_project_routes(settings, owners, now_ms, cache) do
    with {:ok, projects} <- Adapter.fetch_team_projects(settings.tracker.team_key),
         {routes, _rejections} <- discover_project_routes(owners, projects) do
      maybe_log_route_change(routes, cache)

      :persistent_term.put(@cache_key, %{
        routes: routes,
        settings_key: settings_key(settings),
        expires_at_ms: now_ms + settings.github_intake.interval_ms
      })

      {:ok, routes}
    else
      {:error, reason} ->
        Logger.warning("Failed to discover Linear project repository routes: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp discover_project_routes(owners, projects) do
    projects
    |> Enum.reduce({%{}, []}, &record_project_route(&1, &2, owners))
    |> reject_duplicate_routes()
  end

  defp record_project_route(project, {routes, rejections}, owners) when is_map(project) do
    case project_repo_slugs(project) do
      [] ->
        log_rejection(project, :no_repository_url)
        {routes, [{project_label(project), :no_repository_url} | rejections]}

      [slug] ->
        if allowed_owner?(slug, owners) do
          route = %{project: project_name(project), source: :linear_project_metadata}
          {Map.update(routes, slug, [route], &[route | &1]), rejections}
        else
          log_rejection(project, {:owner_not_allowed, repo_owner(slug)})
          {routes, [{project_label(project), {:owner_not_allowed, repo_owner(slug)}} | rejections]}
        end

      slugs ->
        log_rejection(project, {:multiple_repository_urls, slugs})
        {routes, [{project_label(project), {:multiple_repository_urls, slugs}} | rejections]}
    end
  end

  defp reject_duplicate_routes({routes, rejections}) do
    Enum.reduce(routes, {%{}, rejections}, fn {slug, claims}, {accepted, rejected} ->
      claims = Enum.reverse(claims)

      case claims do
        [%{project: project}] ->
          {Map.put(accepted, slug, [project]), rejected}

        claims ->
          projects = Enum.map(claims, & &1.project)
          Logger.warning("Ignoring ambiguous Linear project repository route repo=#{slug} projects=#{inspect(projects)}")
          {accepted, [{slug, {:duplicate_repository_route, projects}} | rejected]}
      end
    end)
  end

  defp project_repo_slugs(project) do
    project
    |> project_repo_sources()
    |> Enum.flat_map(&repo_slugs_from_text/1)
    |> Enum.uniq()
  end

  defp project_repo_sources(project) do
    [
      project_value(project, "description"),
      project_value(project, "url")
    ] ++ project_link_urls(project)
  end

  defp project_link_urls(project) do
    links = project_value(project, "links") || %{}
    nodes = project_value(links, "nodes") || []

    Enum.flat_map(nodes, fn
      link when is_map(link) ->
        case project_value(link, "url") do
          url when is_binary(url) -> [url]
          _ -> []
        end

      _link ->
        []
    end)
  end

  defp repo_slugs_from_text(text) when is_binary(text) do
    @github_repo_url_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(fn
      [owner, repo] -> [canonical_repository_slug("#{owner}/#{repo}")]
      _match -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp repo_slugs_from_text(_text), do: []

  defp static_project_routes(settings) do
    settings
    |> get_in([Access.key(:repository), Access.key(:project_routes)])
    |> case do
      routes when is_map(routes) -> routes
      _ -> %{}
    end
  end

  defp allowed_owners(settings) do
    settings
    |> get_in([Access.key(:repository), Access.key(:allowed_owners)])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp allowed_owner?(slug, owners) do
    slug
    |> repo_owner()
    |> String.downcase()
    |> then(&MapSet.member?(owners, &1))
  end

  defp repo_owner(slug) when is_binary(slug), do: slug |> String.split("/", parts: 2) |> hd()
  defp repo_owner(_slug), do: ""

  defp linear_project_discovery_configured?(settings) do
    settings.tracker.kind == "linear" and is_binary(settings.tracker.team_key) and String.trim(settings.tracker.team_key) != ""
  end

  defp cache_valid?(%{expires_at_ms: expires_at_ms, settings_key: key}, settings, now_ms)
       when is_integer(expires_at_ms) do
    key == settings_key(settings) and now_ms < expires_at_ms
  end

  defp cache_valid?(_cache, _settings, _now_ms), do: false

  defp cached_value do
    :persistent_term.get(@cache_key, nil)
  end

  defp settings_key(settings) do
    %{
      team_key: settings.tracker.team_key,
      interval_ms: settings.github_intake.interval_ms,
      allowed_owners: settings.repository.allowed_owners
    }
  end

  defp maybe_log_route_change(routes, %{routes: routes}), do: :ok

  defp maybe_log_route_change(routes, _cache) do
    route_set =
      routes
      |> Enum.map(fn {repo, [project | _]} -> %{repo: repo, project: project, source: :linear_project_metadata} end)
      |> Enum.sort_by(& &1.repo)

    Logger.info("Discovered Linear project repository routes routes=#{inspect(route_set)}")
  end

  defp log_rejection(project, reason) do
    Logger.warning("Ignoring Linear project repository route project=#{inspect(project_label(project))} reason=#{inspect(reason)}")
  end

  defp project_name(project), do: project_value(project, "name") || project_value(project, "slugId") || project_label(project)

  defp project_label(project) do
    %{
      id: project_value(project, "id"),
      name: project_value(project, "name"),
      slugId: project_value(project, "slugId")
    }
  end

  defp project_value(project, key) when is_map(project) and is_binary(key) do
    Map.get(project, key) || Map.get(project, String.to_atom(key))
  end

  defp repo_name(repo) when is_binary(repo) do
    repo
    |> String.split("/", parts: 2)
    |> List.last()
  end

  defp canonical_route_repo_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("https://github.com/")
    |> String.trim_leading("https://www.github.com/")
    |> String.trim_trailing(".git")
    |> String.downcase()
  end

  defp canonical_route_repo_token(value), do: value |> to_string() |> canonical_route_repo_token()

  defp canonical_repository_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> strip_url_suffix()
    |> String.trim_trailing("/")
    |> strip_git_suffix()
    |> then(fn slug ->
      case String.split(slug, "/", parts: 2) do
        [owner, repo] when owner != "" and repo != "" -> "#{owner}/#{repo}"
        _ -> nil
      end
    end)
  end

  defp canonical_repository_slug(_value), do: nil

  defp strip_url_suffix(value) when is_binary(value) do
    value
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
  end

  defp strip_git_suffix(value) when is_binary(value), do: String.replace_suffix(value, ".git", "")

  defp valid_repo_slug?(value) when is_binary(value), do: Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, value)
  defp valid_repo_slug?(_value), do: false
end
