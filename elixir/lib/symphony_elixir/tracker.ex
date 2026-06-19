defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  require Logger

  alias SymphonyElixir.{Config, RepositoryResolver, RepositoryRoutes}
  alias SymphonyElixir.Linear.Issue

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_zero_touch_evidence(String.t()) :: {:ok, map()} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  @callback remove_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec fetch_zero_touch_evidence(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_zero_touch_evidence(issue_id) do
    adapter().fetch_zero_touch_evidence(issue_id)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec add_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_issue_labels(issue_id, labels) do
    adapter().add_issue_labels(issue_id, labels)
  end

  @spec remove_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def remove_issue_labels(issue_id, labels) do
    adapter().remove_issue_labels(issue_id, labels)
  end

  @spec update_issue_project_from_repository(Issue.t()) :: {:ok, :updated | :skipped} | {:error, term()}
  def update_issue_project_from_repository(issue) do
    update_issue_project_from_repository(issue, nil)
  end

  @spec update_issue_project_from_repository(Issue.t(), Config.Schema.t() | nil) ::
          {:ok, :updated | :skipped} | {:error, term()}
  def update_issue_project_from_repository(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()

    cond do
      issue_project_present?(issue) ->
        {:ok, :skipped}

      not is_binary(issue.id) ->
        Logger.debug("Skipping project auto-assignment; issue has no id for #{issue_context(issue)}")
        {:ok, :skipped}

      not RepositoryResolver.repository_hint?(issue) ->
        Logger.debug("Skipping project auto-assignment; issue has no repository hint for #{issue_context(issue)}")
        {:ok, :skipped}

      not adapter_supports_project_update?() ->
        Logger.debug("Skipping project auto-assignment; tracker adapter does not support project updates")
        {:ok, :skipped}

      true ->
        do_update_issue_project_from_repository(issue, settings)
    end
  end

  def update_issue_project_from_repository(_issue, _settings), do: {:ok, :skipped}

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end

  defp do_update_issue_project_from_repository(%Issue{} = issue, settings) do
    with {:ok, %{slug: repo_slug, name: repo_name}} <- RepositoryResolver.resolve(issue, settings),
         {:ok, projects} <- adapter().fetch_issue_team_projects(issue.id),
         {:ok, project, source} <- unique_project_match(projects, settings, repo_slug, repo_name),
         project_id when is_binary(project_id) <- project_id(project),
         :ok <- adapter().update_issue_project(issue.id, project_id) do
      Logger.info(
        "Auto-assigned Linear project for #{issue_context(issue)} " <>
          "repo=#{repo_slug} project_id=#{project_id} source=#{source}"
      )

      {:ok, :updated}
    else
      {:error, :no_project_match} ->
        Logger.debug("Skipping project auto-assignment; no matching project for #{issue_context(issue)}")
        {:ok, :skipped}

      {:error, {:ambiguous_project_match, projects}} ->
        Logger.warning(
          "Skipping project auto-assignment; multiple matching projects for #{issue_context(issue)} " <>
            "projects=#{inspect(projects)}"
        )

        {:ok, :skipped}

      {:error, reason} ->
        Logger.debug(
          "Skipping project auto-assignment; repository/project lookup failed for #{issue_context(issue)}: " <>
            inspect(reason)
        )

        {:ok, :skipped}

      _ ->
        Logger.warning("Skipping project auto-assignment; matched project has no id for #{issue_context(issue)}")
        {:ok, :skipped}
    end
  end

  defp unique_project_match(projects, settings, repo_slug, repo_name) when is_list(projects) do
    settings
    |> project_alias_groups(repo_slug, repo_name)
    |> match_project_alias_groups(projects)
  end

  defp project_alias_groups(settings, repo_slug, repo_name) do
    route_aliases =
      settings
      |> RepositoryRoutes.effective_project_routes()
      |> RepositoryRoutes.project_route_aliases(repo_slug)

    [
      {:project_route, route_aliases, :exact},
      {:repository_name, [repo_name], :prefix}
    ]
    |> Enum.map(fn {source, aliases, mode} ->
      {source, Enum.map(List.wrap(aliases), &route_token/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(), mode}
    end)
    |> Enum.reject(fn {_source, aliases, _mode} -> aliases == [] end)
  end

  defp match_project_alias_groups([], _projects), do: {:error, :no_project_match}

  defp match_project_alias_groups([{source, aliases, mode} | rest], projects) do
    case matching_projects(projects, aliases, mode) do
      [] -> match_project_alias_groups(rest, projects)
      [project] -> {:ok, project, source}
      matches -> {:error, {:ambiguous_project_match, Enum.map(matches, &project_label/1)}}
    end
  end

  defp matching_projects(projects, aliases, mode) when is_list(projects) do
    projects
    |> Enum.filter(fn project ->
      project
      |> project_tokens()
      |> Enum.any?(fn project_token ->
        Enum.any?(aliases, &alias_matches_project_token?(&1, project_token, mode))
      end)
    end)
    |> Enum.uniq_by(&project_id/1)
  end

  defp alias_matches_project_token?(alias_token, project_token, :prefix) do
    project_token == alias_token or String.starts_with?(project_token, alias_token)
  end

  defp alias_matches_project_token?(alias_token, project_token, :exact), do: project_token == alias_token

  defp project_tokens(project) when is_map(project) do
    [project_value(project, "name"), project_value(project, "slugId"), project_value(project, "slug_id")]
    |> Enum.map(&route_token/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp project_tokens(_project), do: []

  defp project_id(project) when is_map(project), do: project_value(project, "id")
  defp project_id(_project), do: nil

  defp project_label(project) when is_map(project) do
    %{
      id: project_id(project),
      name: project_value(project, "name"),
      slugId: project_value(project, "slugId")
    }
  end

  defp project_label(project), do: project

  defp project_value(project, key) when is_map(project) and is_binary(key) do
    Map.get(project, key) || Map.get(project, String.to_atom(key))
  end

  defp route_token(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp route_token(_value), do: ""

  defp issue_project_present?(%Issue{project_name: project_name, project_slug: project_slug}) do
    route_token(project_name) != "" or route_token(project_slug) != ""
  end

  defp adapter_supports_project_update? do
    adapter = adapter()

    Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :fetch_issue_team_projects, 1) and
      function_exported?(adapter, :update_issue_project, 2)
  end

  defp issue_context(%Issue{} = issue) do
    "issue_id=#{issue.id} issue_identifier=#{issue.identifier}"
  end
end
