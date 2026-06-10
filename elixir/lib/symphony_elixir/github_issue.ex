defmodule SymphonyElixir.GitHubIssue do
  @moduledoc "Small GitHub issue operations used by runtime reconciliation."

  require Logger

  alias SymphonyElixir.Config

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @type sync_result :: %{created: non_neg_integer(), skipped: non_neg_integer(), errors: non_neg_integer()}

  @spec sync_open_issues_to_linear(Config.Schema.t(), module()) :: {:ok, sync_result()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter),
    do: sync_open_issues_to_linear(settings, linear_adapter, runtime_deps())

  @spec sync_open_issues_to_linear(Config.Schema.t(), module(), deps()) :: {:ok, sync_result()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter, deps) when is_atom(linear_adapter) and is_map(deps) do
    cond do
      not github_intake_enabled?(settings) ->
        {:ok, %{created: 0, skipped: 0, errors: 0}}

      not linear_adapter_supports_intake?(linear_adapter) ->
        {:error, {:linear_adapter_missing_github_intake, linear_adapter}}

      true ->
        do_sync_open_issues_to_linear(settings, linear_adapter, deps)
    end
  end

  @spec close_if_open(String.t(), String.t() | nil, String.t()) ::
          {:ok, :closed | :already_closed | :not_applicable} | {:error, term()}
  def close_if_open(repo, issue_url, comment),
    do: close_if_open(repo, issue_url, comment, runtime_deps())

  @spec close_if_open(String.t(), String.t() | nil, String.t(), deps()) ::
          {:ok, :closed | :already_closed | :not_applicable} | {:error, term()}
  def close_if_open(repo, issue_url, comment, deps)
      when is_binary(repo) and is_binary(issue_url) and is_binary(comment) do
    with {:ok, number} <- issue_number_for_repo(repo, issue_url),
         {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, state} <- view_issue_state(gh_bin, repo, number, deps) do
      case String.upcase(to_string(state)) do
        "OPEN" -> close_issue(gh_bin, repo, number, comment, deps)
        "CLOSED" -> {:ok, :already_closed}
        other -> {:error, {:unexpected_issue_state, other}}
      end
    else
      :not_applicable -> {:ok, :not_applicable}
      {:error, reason} -> {:error, reason}
    end
  end

  def close_if_open(_repo, _issue_url, _comment, _deps), do: {:ok, :not_applicable}

  defp do_sync_open_issues_to_linear(settings, linear_adapter, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      settings
      |> configured_repository_slugs()
      |> Enum.reduce({:ok, empty_sync_result()}, &sync_repo_open_issues_result(&1, &2, settings, linear_adapter, gh_bin, deps))
    end
  end

  defp sync_repo_open_issues_result(repo, {:ok, acc}, settings, linear_adapter, gh_bin, deps) do
    case sync_repo_open_issues(repo, settings, linear_adapter, gh_bin, deps) do
      {:ok, repo_result} ->
        {:ok, merge_sync_results(acc, repo_result)}

      {:error, reason} ->
        Logger.warning("Skipping GitHub issue intake for repo=#{repo}; failed to sync: #{inspect(reason)}")
        {:ok, increment_sync_errors(acc)}
    end
  end

  defp sync_repo_open_issues(repo, settings, linear_adapter, gh_bin, deps) do
    with {:ok, issues} <- list_open_issues(gh_bin, repo, settings.github_intake.limit, deps) do
      Enum.reduce(issues, {:ok, empty_sync_result()}, &sync_single_open_issue_result(&1, &2, repo, settings, linear_adapter))
    end
  end

  defp sync_single_open_issue_result(issue, {:ok, acc}, repo, settings, linear_adapter) do
    case sync_single_open_issue(repo, issue, settings, linear_adapter) do
      {:ok, :created} ->
        {:ok, %{acc | created: acc.created + 1}}

      {:ok, :skipped} ->
        {:ok, %{acc | skipped: acc.skipped + 1}}

      {:error, reason} ->
        Logger.warning(
          "Skipping GitHub issue intake for repo=#{repo} url=#{Map.get(issue, :url)}; " <>
            "failed to create Linear issue: #{inspect(reason)}"
        )

        {:ok, increment_sync_errors(acc)}
    end
  end

  defp sync_single_open_issue(repo, %{url: url} = issue, settings, linear_adapter) when is_binary(url) do
    with {:ok, false} <- linear_adapter.github_issue_synced?(url),
         {:ok, target} <-
           linear_adapter.resolve_github_intake_target(
             settings.tracker.team_key,
             settings.github_intake.state,
             project_aliases(settings, repo)
           ),
         {:ok, linear_issue} <-
           linear_adapter.create_github_backlog_issue(%{
             team_id: target.team_id,
             state_id: target.state_id,
             project_id: target.project_id,
             title: github_issue_title(issue),
             description: github_issue_description(repo, issue)
           }),
         issue_id when is_binary(issue_id) <- linear_issue["id"] || linear_issue[:id],
         :ok <- linear_adapter.create_issue_attachment(issue_id, github_issue_attachment_title(issue), url) do
      Logger.info(
        "Created Linear Backlog issue from GitHub issue repo=#{repo} " <>
          "github_issue=#{url} linear_issue=#{linear_issue_label(linear_issue)} project_source=#{target.project_source}"
      )

      {:ok, :created}
    else
      {:ok, true} ->
        {:ok, :skipped}

      {:error, :no_project_match} ->
        Logger.debug("Skipping GitHub issue intake; no matching Linear project for repo=#{repo} url=#{url}")
        {:ok, :skipped}

      {:error, {:ambiguous_project_match, projects}} ->
        Logger.warning(
          "Skipping GitHub issue intake; multiple matching Linear projects for repo=#{repo} " <>
            "url=#{url} projects=#{inspect(projects)}"
        )

        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_intake_linear_issue_missing_id}
    end
  end

  defp sync_single_open_issue(_repo, _issue, _settings, _linear_adapter), do: {:ok, :skipped}

  defp list_open_issues(gh_bin, repo, limit, deps) do
    args = [
      "issue",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--limit",
      Integer.to_string(limit),
      "--json",
      "number,title,body,url"
    ]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_issue_list(output)
      {:ok, {output, status}} -> {:error, {:gh_issue_list_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_list_failed, reason}}
    end
  end

  defp parse_issue_list(output) do
    case Jason.decode(output) do
      {:ok, issues} when is_list(issues) ->
        {:ok, issues |> Enum.map(&normalize_open_issue/1) |> Enum.reject(&is_nil/1)}

      {:ok, other} ->
        {:error, {:invalid_issue_list_payload, other}}

      {:error, reason} ->
        {:error, {:gh_json_error, reason}}
    end
  end

  defp normalize_open_issue(%{"url" => url} = issue) when is_binary(url) do
    %{
      number: issue["number"],
      title: issue["title"],
      body: issue["body"],
      url: url
    }
  end

  defp normalize_open_issue(_issue), do: nil

  defp configured_repository_slugs(settings) do
    project_route_repos =
      settings.repository.project_routes
      |> case do
        routes when is_map(routes) -> Map.keys(routes)
        _ -> []
      end

    [settings.repository.default | project_route_repos]
    |> Enum.map(&canonical_repo_slug/1)
    |> Enum.filter(&valid_repo_slug?/1)
    |> Enum.uniq()
  end

  defp project_aliases(settings, repo) do
    route_aliases =
      settings.repository.project_routes
      |> case do
        routes when is_map(routes) ->
          Map.get(routes, repo) || []

        _ ->
          []
      end
      |> List.wrap()

    (route_aliases ++ [repo_name(repo)])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp repo_name(repo) when is_binary(repo) do
    repo
    |> String.split("/", parts: 2)
    |> List.last()
  end

  defp repo_name(_repo), do: nil

  defp github_issue_title(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "GitHub issue"
      title -> title
    end
  end

  defp github_issue_title(%{number: number}) when not is_nil(number), do: "GitHub issue ##{number}"
  defp github_issue_title(_issue), do: "GitHub issue"

  defp github_issue_attachment_title(%{number: number, title: title}) when not is_nil(number) and is_binary(title) do
    case String.trim(title) do
      "" -> "GitHub issue ##{number}"
      title -> "GitHub issue ##{number}: #{title}"
    end
  end

  defp github_issue_attachment_title(%{number: number}) when not is_nil(number), do: "GitHub issue ##{number}"
  defp github_issue_attachment_title(issue), do: github_issue_title(issue)

  defp github_issue_description(repo, %{url: url} = issue) do
    body =
      case Map.get(issue, :body) do
        body when is_binary(body) -> String.trim(body)
        _ -> ""
      end

    [
      "Repo: #{repo}",
      "GitHub Issue: #{url}",
      body
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp linear_issue_label(%{"identifier" => identifier, "url" => url}), do: "#{identifier} #{url}"
  defp linear_issue_label(%{"identifier" => identifier}), do: identifier
  defp linear_issue_label(%{"id" => id}), do: id
  defp linear_issue_label(issue), do: inspect(issue)

  defp github_intake_enabled?(%{github_intake: %{enabled: true}, tracker: %{kind: "linear"}}), do: true
  defp github_intake_enabled?(_settings), do: false

  defp linear_adapter_supports_intake?(linear_adapter) do
    Code.ensure_loaded?(linear_adapter) and
      function_exported?(linear_adapter, :github_issue_synced?, 1) and
      function_exported?(linear_adapter, :resolve_github_intake_target, 3) and
      function_exported?(linear_adapter, :create_github_backlog_issue, 1) and
      function_exported?(linear_adapter, :create_issue_attachment, 3)
  end

  defp canonical_repo_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("https://github.com/")
    |> String.trim_trailing(".git")
  end

  defp canonical_repo_slug(value) when is_atom(value), do: value |> Atom.to_string() |> canonical_repo_slug()
  defp canonical_repo_slug(_value), do: ""

  defp valid_repo_slug?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, value)
  end

  defp valid_repo_slug?(_value), do: false

  defp merge_sync_results(left, right) do
    %{
      created: left.created + right.created,
      skipped: left.skipped + right.skipped,
      errors: left.errors + right.errors
    }
  end

  defp increment_sync_errors(result), do: %{result | errors: result.errors + 1}

  defp empty_sync_result, do: %{created: 0, skipped: 0, errors: 0}

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3
    }
  end

  defp run_system_cmd(cmd, args, opts), do: {:ok, System.cmd(cmd, args, opts)}

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp issue_number_for_repo(repo, issue_url) do
    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/issues/(\d+)(?:[/?#].*)?$}i, String.trim(issue_url)) do
      [_, ^repo, number] -> {:ok, String.to_integer(number)}
      [_matched, _other_repo, _number] -> :not_applicable
      _other -> :not_applicable
    end
  end

  defp view_issue_state(gh_bin, repo, number, deps) do
    args = ["issue", "view", Integer.to_string(number), "--repo", repo, "--json", "state"]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_issue_state(output)
      {:ok, {output, status}} -> {:error, {:gh_issue_view_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_view_failed, reason}}
    end
  end

  defp parse_issue_state(output) do
    case Jason.decode(output) do
      {:ok, %{"state" => state}} when is_binary(state) -> {:ok, state}
      {:ok, other} -> {:error, {:invalid_issue_payload, other}}
      {:error, reason} -> {:error, {:gh_json_error, reason}}
    end
  end

  defp close_issue(gh_bin, repo, number, comment, deps) do
    args = ["issue", "close", Integer.to_string(number), "--repo", repo, "--comment", comment]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {_output, 0}} -> {:ok, :closed}
      {:ok, {output, status}} -> {:error, {:gh_issue_close_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_close_failed, reason}}
    end
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result
end
