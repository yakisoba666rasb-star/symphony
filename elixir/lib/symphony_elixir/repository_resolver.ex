defmodule SymphonyElixir.RepositoryResolver do
  @moduledoc """
  Resolves the GitHub repository context for a Linear issue.

  The runtime keeps Linear as the queue source of truth, but the implementation
  workspace needs a repository. This resolver follows an official-style
  configuration contract: GitHub-synced issue metadata can name the repo, while
  WORKFLOW.md provides a safe default.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @slug_regex ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
  @repo_line_regex ~r/(?im)^\s*(?:repo|repository)\s*:\s*<?((?:https:\/\/(?:www\.)?github\.com\/)?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/?(?:[?#][^\s>]*)?)>?\s*$/
  @source_github_url_regex ~r/(?im)^\s*(?:source|github issue|github pull request|github pr)\s*:\s*(https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:issues|pull)\/\d+)\s*$/
  @github_url_regex ~r/(?i)https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:\/(?:issues|pull)\/\d+)?/
  @github_issue_url_regex ~r/(?i)https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/\d+/
  @non_repository_github_owners MapSet.new([
                                  "advisories",
                                  "apps",
                                  "codespaces",
                                  "collections",
                                  "dashboard",
                                  "enterprise",
                                  "events",
                                  "explore",
                                  "features",
                                  "issues",
                                  "login",
                                  "marketplace",
                                  "new",
                                  "notifications",
                                  "orgs",
                                  "organizations",
                                  "pricing",
                                  "pulls",
                                  "search",
                                  "settings",
                                  "sponsors",
                                  "topics",
                                  "trending"
                                ])

  @type context :: %{
          slug: String.t() | nil,
          owner: String.t() | nil,
          name: String.t() | nil,
          clone_url: String.t() | nil,
          github_issue_url: String.t() | nil
        }

  @spec resolve(map() | String.t() | nil, Config.Schema.t() | nil) ::
          {:ok, context()} | {:error, term()}
  def resolve(issue_or_identifier, settings \\ nil) do
    settings = settings || Config.settings!()
    text = issue_text(issue_or_identifier)

    explicit_slug = repo_from_explicit_line(text)
    source_url = source_github_url(text)
    source_slug = source_url && repo_from_github_url(source_url)
    github_slugs = github_slugs(text)
    inferred_slug = single_github_slug(github_slugs)
    slug = explicit_slug || source_slug || inferred_slug || normalize_blank(settings.repository.default)

    with :ok <- validate_source_consistency(explicit_slug, source_slug),
         :ok <- validate_github_url_ambiguity(explicit_slug || source_slug, github_slugs),
         {:ok, slug} <- normalize_slug(slug) do
      {:ok,
       build_context(
         slug,
         settings.repository.clone_protocol,
         source_url || first_github_issue_url(text)
       )}
    end
  end

  @spec resolve!(map() | String.t() | nil, Config.Schema.t() | nil) :: context()
  def resolve!(issue_or_identifier, settings \\ nil) do
    case resolve(issue_or_identifier, settings) do
      {:ok, context} ->
        context

      {:error, reason} ->
        raise ArgumentError, "invalid repository context: #{inspect(reason)}"
    end
  end

  @spec source_github_issue_url(map() | String.t() | nil) :: String.t() | nil
  def source_github_issue_url(issue_or_identifier) do
    text = issue_text(issue_or_identifier)
    source_github_url(text) || first_github_issue_url(text)
  end

  @spec repository_hint?(map() | String.t() | nil) :: boolean()
  def repository_hint?(issue_or_identifier) do
    text = issue_text(issue_or_identifier)
    not is_nil(repo_from_explicit_line(text)) or github_slugs(text) != []
  end

  defp issue_text(%Issue{} = issue) do
    [issue.title, issue.description, issue.url | issue.attachment_urls || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp issue_text(%{} = issue) do
    [
      "title",
      "description",
      "body",
      "url",
      "attachment_urls",
      "attachmentUrls",
      :title,
      :description,
      :body,
      :url,
      :attachment_urls,
      :attachmentUrls
    ]
    |> Enum.map(&Map.get(issue, &1))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp issue_text(_issue_or_identifier), do: ""

  defp repo_from_explicit_line(text) when is_binary(text) do
    case Regex.run(@repo_line_regex, text, capture: :all_but_first) do
      [slug] -> canonical_repository_slug(slug)
      _ -> nil
    end
  end

  defp repo_from_github_url(text) when is_binary(text) do
    case Regex.run(@github_url_regex, text, capture: :all_but_first) do
      [owner, repo] -> canonical_repository_slug("#{owner}/#{repo}")
      _ -> nil
    end
  end

  defp github_slugs(text) when is_binary(text) do
    @github_url_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn
      [owner, repo] ->
        if github_repository_owner?(owner) do
          canonical_repository_slug("#{owner}/#{repo}")
        else
          nil
        end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp single_github_slug([slug]), do: slug
  defp single_github_slug(_slugs), do: nil

  defp source_github_url(text) when is_binary(text) do
    case Regex.run(@source_github_url_regex, text, capture: :all_but_first) do
      [url] -> url
      _ -> nil
    end
  end

  defp first_github_issue_url(text) when is_binary(text) do
    case Regex.run(@github_issue_url_regex, text) do
      [url | _] -> url
      _ -> nil
    end
  end

  defp validate_source_consistency(nil, _github_slug), do: :ok
  defp validate_source_consistency(_explicit_slug, nil), do: :ok
  defp validate_source_consistency(slug, slug), do: :ok

  defp validate_source_consistency(explicit_slug, github_slug) do
    {:error, {:repository_source_conflict, explicit_slug, github_slug}}
  end

  defp validate_github_url_ambiguity(nil, slugs) when length(slugs) > 1 do
    {:error, {:ambiguous_repository_urls, slugs}}
  end

  defp validate_github_url_ambiguity(_selected_slug, _slugs), do: :ok

  defp normalize_slug(nil), do: {:ok, nil}

  defp normalize_slug(slug) when is_binary(slug) do
    normalized = canonical_repository_slug(slug)

    cond do
      is_nil(normalized) ->
        {:ok, nil}

      Regex.match?(@slug_regex, normalized) ->
        {:ok, normalized}

      true ->
        {:error, {:invalid_repository_slug, slug}}
    end
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp normalize_blank(value), do: value

  defp canonical_repository_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> do_canonical_repository_slug()
  end

  defp canonical_repository_slug(_value), do: nil

  defp do_canonical_repository_slug(""), do: nil

  defp do_canonical_repository_slug(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] and is_binary(host) ->
        if String.downcase(host) in ["github.com", "www.github.com"] do
          slug_from_github_path(path)
        else
          invalid_url_slug(value)
        end

      _uri ->
        value
        |> strip_url_suffix()
        |> String.trim_trailing("/")
        |> strip_git_suffix()
    end
  end

  defp slug_from_github_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [owner, repo | _rest] ->
        if github_repository_owner?(owner) do
          "#{owner}/#{strip_git_suffix(repo)}"
        else
          nil
        end

      _segments ->
        nil
    end
  end

  defp slug_from_github_path(_path), do: nil

  defp github_repository_owner?(owner) when is_binary(owner) do
    owner
    |> String.downcase()
    |> then(fn normalized_owner -> not MapSet.member?(@non_repository_github_owners, normalized_owner) end)
  end

  defp invalid_url_slug(value) do
    value
    |> strip_url_suffix()
    |> String.trim_trailing("/")
    |> strip_git_suffix()
  end

  defp strip_url_suffix(value) when is_binary(value) do
    value
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
  end

  defp strip_git_suffix(value) when is_binary(value) do
    String.replace_suffix(value, ".git", "")
  end

  defp build_context(nil, _clone_protocol, github_issue_url) do
    %{
      slug: nil,
      owner: nil,
      name: nil,
      clone_url: nil,
      github_issue_url: github_issue_url
    }
  end

  defp build_context(slug, clone_protocol, github_issue_url) when is_binary(slug) do
    [owner, name] = String.split(slug, "/", parts: 2)

    %{
      slug: slug,
      owner: owner,
      name: name,
      clone_url: clone_url(slug, clone_protocol),
      github_issue_url: github_issue_url
    }
  end

  defp clone_url(slug, "ssh"), do: "git@github.com:#{slug}.git"
  defp clone_url(slug, _protocol), do: "https://github.com/#{slug}.git"
end
