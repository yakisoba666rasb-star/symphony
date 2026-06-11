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
  @type intake_attempt :: %{reason: term(), attempts: pos_integer(), last_attempt_ms: integer()}
  @type intake_attempts :: %{optional(String.t()) => intake_attempt()}

  @spec sync_open_issues_to_linear(Config.Schema.t(), module()) :: {:ok, sync_result()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter) do
    case sync_open_issues_to_linear(settings, linear_adapter, %{}, runtime_deps()) do
      {:ok, result, _attempts} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec sync_open_issues_to_linear(Config.Schema.t(), module(), deps()) :: {:ok, sync_result()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter, %{run_command: _} = deps) do
    case sync_open_issues_to_linear(settings, linear_adapter, %{}, deps) do
      {:ok, result, _attempts} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec sync_open_issues_to_linear(Config.Schema.t(), module(), intake_attempts()) ::
          {:ok, sync_result(), intake_attempts()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter, attempts) when is_map(attempts),
    do: sync_open_issues_to_linear(settings, linear_adapter, attempts, runtime_deps())

  @spec sync_open_issues_to_linear(Config.Schema.t(), module(), intake_attempts(), deps()) ::
          {:ok, sync_result(), intake_attempts()} | {:error, term()}
  def sync_open_issues_to_linear(settings, linear_adapter, attempts, deps)
      when is_atom(linear_adapter) and is_map(attempts) and is_map(deps) do
    cond do
      not github_intake_enabled?(settings) ->
        {:ok, %{created: 0, skipped: 0, errors: 0}, attempts}

      not linear_adapter_supports_intake?(linear_adapter) ->
        {:error, {:linear_adapter_missing_github_intake, linear_adapter}}

      true ->
        do_sync_open_issues_to_linear(settings, linear_adapter, attempts, deps)
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

  defp do_sync_open_issues_to_linear(settings, linear_adapter, attempts, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      settings
      |> configured_repository_slugs()
      |> Enum.reduce(
        {:ok, empty_sync_result(), attempts},
        &sync_repo_open_issues_result(&1, &2, settings, linear_adapter, gh_bin, deps)
      )
    end
  end

  defp sync_repo_open_issues_result(repo, {:ok, acc, attempts}, settings, linear_adapter, gh_bin, deps) do
    case sync_repo_open_issues(repo, settings, linear_adapter, attempts, gh_bin, deps) do
      {:ok, repo_result, attempts} ->
        {:ok, merge_sync_results(acc, repo_result), attempts}

      {:error, reason} ->
        Logger.warning("Skipping GitHub issue intake for repo=#{repo}; failed to sync: #{inspect(reason)}")
        {:ok, increment_sync_errors(acc), attempts}
    end
  end

  defp sync_repo_open_issues(repo, settings, linear_adapter, attempts, gh_bin, deps) do
    with {:ok, issues} <- list_open_issues(gh_bin, repo, settings.github_intake.limit, deps),
         :ok <- warn_when_issue_limit_reached(repo, issues, settings.github_intake.limit) do
      attempts = prune_disappeared_attempts(attempts, repo, issues)
      sync_listed_repo_issues(repo, issues, settings, linear_adapter, attempts, deps)
    end
  end

  defp sync_listed_repo_issues(_repo, [], _settings, _linear_adapter, attempts, _deps),
    do: {:ok, empty_sync_result(), attempts}

  defp sync_listed_repo_issues(repo, issues, settings, linear_adapter, attempts, deps) do
    now_ms = current_time_ms(deps)

    {retryable_issues, cached_skips} =
      split_retryable_issues(issues, attempts, settings.github_intake.retry_ttl_ms, now_ms)

    if retryable_issues == [] do
      {:ok, %{empty_sync_result() | skipped: cached_skips}, attempts}
    else
      case linear_adapter.resolve_github_intake_target(
             settings.tracker.team_key,
             settings.github_intake.state,
             project_aliases(settings, repo)
           ) do
        {:ok, target} ->
          retryable_issues
          |> Enum.reduce(
            {:ok, %{empty_sync_result() | skipped: cached_skips}, attempts},
            &sync_single_open_issue_result(&1, &2, repo, target, linear_adapter, now_ms)
          )

        {:error, :no_project_match} ->
          Logger.debug("Skipping GitHub issue intake; no matching Linear project for repo=#{repo}")

          result = %{empty_sync_result() | skipped: cached_skips + length(retryable_issues)}
          updated_attempts = record_failed_attempts(attempts, retryable_issues, :no_project_match, now_ms)
          {:ok, result, updated_attempts}

        {:error, {:ambiguous_project_match, projects}} ->
          Logger.warning(
            "Skipping GitHub issue intake; multiple matching Linear projects for repo=#{repo} " <>
              "projects=#{inspect(projects)}"
          )

          result = %{empty_sync_result() | skipped: cached_skips + length(retryable_issues)}
          reason = {:ambiguous_project_match, projects}
          updated_attempts = record_failed_attempts(attempts, retryable_issues, reason, now_ms)
          {:ok, result, updated_attempts}

        {:error, reason} ->
          result = %{empty_sync_result() | skipped: cached_skips, errors: length(retryable_issues)}
          updated_attempts = record_failed_attempts(attempts, retryable_issues, reason, now_ms)
          {:ok, result, updated_attempts}
      end
    end
  end

  defp sync_single_open_issue_result(issue, {:ok, acc, attempts}, repo, target, linear_adapter, now_ms) do
    case sync_single_open_issue(repo, issue, target, linear_adapter) do
      {:ok, :created} ->
        {:ok, %{acc | created: acc.created + 1}, clear_attempt(attempts, issue)}

      {:ok, :skipped} ->
        {:ok, %{acc | skipped: acc.skipped + 1}, clear_attempt(attempts, issue)}

      {:error, reason} ->
        Logger.warning(
          "Skipping GitHub issue intake for repo=#{repo} url=#{Map.get(issue, :url)}; " <>
            "failed to create Linear issue: #{inspect(reason)}"
        )

        {:ok, increment_sync_errors(acc), record_failed_attempt(attempts, issue, reason, now_ms)}
    end
  end

  defp prune_disappeared_attempts(attempts, repo, issues) do
    listed_urls = issues |> Enum.map(&Map.get(&1, :url)) |> MapSet.new()

    Map.reject(attempts, fn {url, _attempt} ->
      issue_url_repo(url) == repo and not MapSet.member?(listed_urls, url)
    end)
  end

  defp split_retryable_issues(issues, attempts, retry_ttl_ms, now_ms) do
    Enum.reduce(issues, {[], 0}, fn %{url: url} = issue, {retryable, skipped} ->
      case Map.get(attempts, url) do
        %{last_attempt_ms: last_attempt_ms}
        when is_integer(last_attempt_ms) and now_ms - last_attempt_ms < retry_ttl_ms ->
          {retryable, skipped + 1}

        _attempt ->
          {[issue | retryable], skipped}
      end
    end)
    |> then(fn {retryable, skipped} -> {Enum.reverse(retryable), skipped} end)
  end

  defp record_failed_attempts(attempts, issues, reason, now_ms) do
    Enum.reduce(issues, attempts, &record_failed_attempt(&2, &1, reason, now_ms))
  end

  defp record_failed_attempt(attempts, %{url: url}, reason, now_ms) when is_binary(url) do
    prior_attempts =
      attempts
      |> Map.get(url, %{})
      |> Map.get(:attempts, 0)

    Map.put(attempts, url, %{reason: reason, attempts: prior_attempts + 1, last_attempt_ms: now_ms})
  end

  defp record_failed_attempt(attempts, _issue, _reason, _now_ms), do: attempts

  defp clear_attempt(attempts, %{url: url}) when is_binary(url), do: Map.delete(attempts, url)
  defp clear_attempt(attempts, _issue), do: attempts

  defp current_time_ms(%{monotonic_time_ms: monotonic_time_ms}) when is_function(monotonic_time_ms, 0),
    do: monotonic_time_ms.()

  defp current_time_ms(_deps), do: System.monotonic_time(:millisecond)

  defp sync_single_open_issue(repo, %{url: url} = issue, target, linear_adapter) when is_binary(url) do
    with {:ok, false} <- linear_adapter.github_issue_synced?(url),
         {:ok, nil} <- linear_adapter.find_github_issue_by_description(url),
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

      {:ok, %{} = existing_issue} ->
        repair_github_issue_attachment(repo, issue, existing_issue, linear_adapter)

      {:error, :github_issue_description_lookup_failed} ->
        {:error, :github_issue_description_lookup_failed}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_intake_linear_issue_missing_id}
    end
  end

  defp sync_single_open_issue(_repo, _issue, _target, _linear_adapter), do: {:ok, :skipped}

  defp repair_github_issue_attachment(repo, %{url: url} = issue, existing_issue, linear_adapter) do
    with issue_id when is_binary(issue_id) <- existing_issue["id"] || existing_issue[:id],
         :ok <- linear_adapter.create_issue_attachment(issue_id, github_issue_attachment_title(issue), url) do
      Logger.info(
        "Repaired missing Linear attachment for GitHub issue repo=#{repo} " <>
          "github_issue=#{url} linear_issue=#{linear_issue_label(existing_issue)}"
      )

      {:ok, :skipped}
    else
      {:error, reason} ->
        {:error, {:github_intake_attachment_repair_failed, reason}}

      _ ->
        {:error, :github_intake_existing_issue_missing_id}
    end
  end

  defp warn_when_issue_limit_reached(repo, issues, limit) when is_list(issues) and is_integer(limit) do
    if length(issues) >= limit do
      Logger.warning("GitHub issue intake reached configured limit for repo=#{repo} limit=#{limit}; remaining open issues may be deferred")
    end

    :ok
  end

  defp warn_when_issue_limit_reached(_repo, _issues, _limit), do: :ok

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
      function_exported?(linear_adapter, :find_github_issue_by_description, 1) and
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

  defp issue_url_repo(issue_url) when is_binary(issue_url) do
    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/issues/\d+(?:[/?#].*)?$}i, String.trim(issue_url)) do
      [_, repo] -> repo
      _other -> nil
    end
  end

  defp issue_url_repo(_issue_url), do: nil

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
