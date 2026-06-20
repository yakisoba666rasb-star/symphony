defmodule SymphonyElixir.GitHubIssue do
  @moduledoc "Small GitHub issue operations used by runtime reconciliation."

  require Logger

  alias SymphonyElixir.{Config, GitHubCommand, RepositoryRoutes}

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
        "MERGED" -> {:ok, :not_applicable}
        other -> {:error, {:unexpected_issue_state, other}}
      end
    else
      :not_applicable -> {:ok, :not_applicable}
      {:error, reason} -> {:error, reason}
    end
  end

  def close_if_open(_repo, _issue_url, _comment, _deps), do: {:ok, :not_applicable}

  @spec closed_at(String.t(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def closed_at(repo, issue_url), do: closed_at(repo, issue_url, runtime_deps())

  @spec closed_at(String.t(), String.t() | nil, deps()) :: {:ok, String.t() | nil} | {:error, term()}
  def closed_at(repo, issue_url, deps) when is_binary(repo) and is_binary(issue_url) do
    with {:ok, number} <- issue_number_for_repo(repo, issue_url),
         {:ok, gh_bin} <- find_gh_binary(deps) do
      view_issue_closed_at(gh_bin, repo, number, deps)
    else
      :not_applicable -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def closed_at(_repo, _issue_url, _deps), do: {:ok, nil}

  defp do_sync_open_issues_to_linear(settings, linear_adapter, attempts, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      sync_result =
        settings
        |> RepositoryRoutes.configured_repository_slugs()
        |> Enum.reduce(
          {:ok, empty_sync_result(), attempts, MapSet.new()},
          &sync_repo_open_issues_result(&1, &2, settings, linear_adapter, gh_bin, deps)
        )

      case sync_result do
        {:ok, result, attempts, _seen_urls} -> {:ok, result, attempts}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sync_repo_open_issues_result(repo, {:ok, acc, attempts, seen_urls}, settings, linear_adapter, gh_bin, deps) do
    case sync_repo_open_issues(repo, settings, linear_adapter, attempts, seen_urls, gh_bin, deps) do
      {:ok, repo_result, attempts, seen_urls} ->
        {:ok, merge_sync_results(acc, repo_result), attempts, seen_urls}

      {:error, reason} ->
        Logger.warning("Skipping GitHub issue intake for repo=#{repo}; failed to sync: #{inspect(reason)}")
        {:ok, increment_sync_errors(acc), attempts, seen_urls}
    end
  end

  defp sync_repo_open_issues(repo, settings, linear_adapter, attempts, seen_urls, gh_bin, deps) do
    with {:ok, issues} <- list_open_issues(gh_bin, repo, settings.github_intake.limit, deps),
         :ok <- warn_when_issue_limit_reached(repo, issues, settings.github_intake.limit) do
      attempts = prune_disappeared_attempts(attempts, repo, issues)
      sync_listed_repo_issues(repo, issues, settings, linear_adapter, attempts, seen_urls, deps)
    end
  end

  defp sync_listed_repo_issues(_repo, [], _settings, _linear_adapter, attempts, seen_urls, _deps),
    do: {:ok, empty_sync_result(), attempts, seen_urls}

  defp sync_listed_repo_issues(repo, issues, settings, linear_adapter, attempts, seen_urls, deps) do
    now_ms = current_time_ms(deps)

    {retryable_issues, cached_skips} =
      split_retryable_issues(issues, attempts, settings.github_intake.retry_ttl_ms, now_ms)

    if retryable_issues == [] do
      {:ok, %{empty_sync_result() | skipped: cached_skips}, attempts, seen_urls}
    else
      retryable_issues
      |> Enum.group_by(&github_intake_target_state(settings, &1))
      |> Enum.reduce(
        {:ok, %{empty_sync_result() | skipped: cached_skips}, attempts, seen_urls},
        &sync_issue_group_result(&1, &2, repo, settings, linear_adapter, now_ms)
      )
    end
  end

  defp sync_issue_group_result({_state, _issues}, {:error, _reason} = error, _repo, _settings, _linear_adapter, _now_ms),
    do: error

  defp sync_issue_group_result({state, issues}, {:ok, acc, attempts, seen_urls}, repo, settings, linear_adapter, now_ms) do
    case linear_adapter.resolve_github_intake_target(
           settings.tracker.team_key,
           state,
           RepositoryRoutes.project_aliases(settings, repo)
         ) do
      {:ok, target} ->
        context = %{repo: repo, settings: settings, target: target, linear_adapter: linear_adapter, now_ms: now_ms}

        issues
        |> Enum.reduce(
          {:ok, acc, attempts, seen_urls},
          &sync_single_open_issue_result(&1, &2, context)
        )

      {:error, :no_project_match} ->
        Logger.debug("Skipping GitHub issue intake; no matching Linear project for repo=#{repo}")

        result = %{acc | skipped: acc.skipped + length(issues)}
        updated_attempts = record_failed_attempts(attempts, issues, :no_project_match, now_ms)
        {:ok, result, updated_attempts, seen_urls}

      {:error, {:ambiguous_project_match, projects}} ->
        Logger.warning(
          "Skipping GitHub issue intake; multiple matching Linear projects for repo=#{repo} " <>
            "projects=#{inspect(projects)}"
        )

        reason = {:ambiguous_project_match, projects}
        result = %{acc | skipped: acc.skipped + length(issues)}
        updated_attempts = record_failed_attempts(attempts, issues, reason, now_ms)
        {:ok, result, updated_attempts, seen_urls}

      {:error, reason} ->
        result = %{acc | errors: acc.errors + length(issues)}
        updated_attempts = record_failed_attempts(attempts, issues, reason, now_ms)
        {:ok, result, updated_attempts, seen_urls}
    end
  end

  defp sync_single_open_issue_result(%{url: url} = issue, {:ok, acc, attempts, seen_urls}, context)
       when is_binary(url) do
    if MapSet.member?(seen_urls, url) do
      # Count duplicate route hits as skipped so totals still describe every listed issue.
      {:ok, %{acc | skipped: acc.skipped + 1}, clear_attempt(attempts, issue), seen_urls}
    else
      sync_unseen_open_issue_result(issue, acc, attempts, seen_urls, context)
    end
  end

  defp sync_single_open_issue_result(issue, {:ok, acc, attempts, seen_urls}, context) do
    sync_unseen_open_issue_result(issue, acc, attempts, seen_urls, context)
  end

  defp sync_unseen_open_issue_result(issue, acc, attempts, seen_urls, context) do
    case sync_single_open_issue(context.repo, issue, context.settings, context.target, context.linear_adapter) do
      {:ok, :created} ->
        {:ok, %{acc | created: acc.created + 1}, clear_attempt(attempts, issue), mark_seen_url(seen_urls, issue)}

      {:ok, :skipped} ->
        {:ok, %{acc | skipped: acc.skipped + 1}, clear_attempt(attempts, issue), mark_seen_url(seen_urls, issue)}

      {:ok, {:deferred, reason}} ->
        attempts = record_failed_attempt(attempts, issue, reason, context.now_ms)
        seen_urls = mark_seen_url(seen_urls, issue)

        {:ok, %{acc | skipped: acc.skipped + 1}, attempts, seen_urls}

      {:error, reason} ->
        Logger.warning(
          "Skipping GitHub issue intake for repo=#{context.repo} url=#{Map.get(issue, :url)}; " <>
            "failed to create Linear issue: #{inspect(reason)}"
        )

        {:ok, increment_sync_errors(acc), record_failed_attempt(attempts, issue, reason, context.now_ms), seen_urls}
    end
  end

  defp mark_seen_url(seen_urls, %{url: url}) when is_binary(url), do: MapSet.put(seen_urls, url)
  defp mark_seen_url(seen_urls, _issue), do: seen_urls

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

  defp sync_single_open_issue(repo, %{url: url} = issue, settings, target, linear_adapter) when is_binary(url) do
    with {:ok, false} <- linear_adapter.github_issue_synced?(url),
         {:ok, nil} <- linear_adapter.find_github_issue_by_description(url),
         :ok <- maybe_defer_linear_issue_create(settings, repo, url),
         {:ok, label_ids} <- github_intake_label_ids(settings, issue, target, linear_adapter),
         {:ok, linear_issue} <-
           linear_adapter.create_github_backlog_issue(github_intake_create_attrs(repo, issue, target, label_ids)),
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

      {:defer, reason} ->
        Logger.info(
          "Deferring GitHub issue intake Linear issue creation for repo=#{repo} " <>
            "github_issue=#{url} reason=#{inspect(reason)}"
        )

        {:ok, {:deferred, reason}}

      {:error, :github_issue_description_lookup_failed} ->
        {:error, :github_issue_description_lookup_failed}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_intake_linear_issue_missing_id}
    end
  end

  defp sync_single_open_issue(_repo, _issue, _settings, _target, _linear_adapter), do: {:ok, :skipped}

  defp maybe_defer_linear_issue_create(settings, repo, _url) do
    if linear_issue_create_disabled_repo?(settings, repo) do
      {:defer, {:linear_official_sync_pending, repo}}
    else
      :ok
    end
  end

  defp linear_issue_create_disabled_repo?(%{github_intake: %{linear_issue_create_disabled_repos: repos}}, repo)
       when is_list(repos) and is_binary(repo) do
    normalized_repo = normalize_repo_slug(repo)
    Enum.any?(repos, &(normalize_repo_slug(&1) == normalized_repo))
  end

  defp linear_issue_create_disabled_repo?(_settings, _repo), do: false

  defp normalize_repo_slug(repo) when is_binary(repo), do: repo |> String.trim() |> String.downcase()
  defp normalize_repo_slug(_repo), do: ""

  defp github_intake_create_attrs(repo, issue, target, label_ids) do
    %{
      team_id: target.team_id,
      state_id: target.state_id,
      project_id: target.project_id,
      label_ids: label_ids,
      title: github_issue_title(issue),
      description: github_issue_description(repo, issue)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp github_intake_label_ids(%{github_intake: %{mirror_labels: true}}, issue, target, linear_adapter) do
    labels = issue |> Map.get(:labels, []) |> normalized_label_names()

    cond do
      labels == [] ->
        {:ok, nil}

      not function_exported?(linear_adapter, :resolve_or_create_github_intake_label_ids, 2) ->
        Logger.warning(
          "Skipping GitHub issue label mirroring for url=#{Map.get(issue, :url)}; " <>
            "Linear adapter does not support label resolution"
        )

        {:ok, nil}

      true ->
        case linear_adapter.resolve_or_create_github_intake_label_ids(target.team_id, labels) do
          {:ok, []} ->
            {:ok, nil}

          {:ok, label_ids} ->
            {:ok, label_ids}

          {:error, reason} ->
            Logger.warning(
              "Skipping GitHub issue label mirroring for url=#{Map.get(issue, :url)}; " <>
                "failed to resolve Linear labels: #{inspect(reason)}"
            )

            {:ok, nil}
        end
    end
  end

  defp github_intake_label_ids(_settings, _issue, _target, _linear_adapter), do: {:ok, nil}

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
      "number,title,body,url,labels"
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
      url: url,
      labels: github_issue_label_names(issue["labels"])
    }
  end

  defp normalize_open_issue(_issue), do: nil

  defp github_issue_label_names(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp github_issue_label_names(_labels), do: []

  defp github_intake_target_state(settings, issue) do
    todo_state = first_active_state(settings)

    if is_binary(todo_state) and github_issue_matches_todo_label?(issue, settings.github_intake.todo_labels) do
      todo_state
    else
      settings.github_intake.state
    end
  end

  defp first_active_state(%{tracker: %{active_states: [state | _]}}) when is_binary(state), do: state
  defp first_active_state(_settings), do: nil

  defp github_issue_matches_todo_label?(_issue, []), do: false

  defp github_issue_matches_todo_label?(issue, todo_labels) when is_list(todo_labels) do
    configured_labels =
      todo_labels
      |> Enum.map(&normalized_label_name/1)
      |> MapSet.new()

    issue
    |> Map.get(:labels, [])
    |> Enum.map(&normalized_label_name/1)
    |> Enum.any?(&MapSet.member?(configured_labels, &1))
  end

  defp github_issue_matches_todo_label?(_issue, _todo_labels), do: false

  defp normalized_label_names(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      label when is_binary(label) ->
        case String.trim(label) do
          "" -> []
          trimmed -> [trimmed]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&normalized_label_name/1)
  end

  defp normalized_label_names(_labels), do: []

  defp normalized_label_name(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

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

  defp run_system_cmd(cmd, args, opts), do: GitHubCommand.run_system_cmd(cmd, args, opts)

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp issue_number_for_repo(repo, issue_url) do
    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/issues/(\d+)(?:[/?#].*)?$}i, String.trim(issue_url)) do
      [_, url_repo, number] ->
        if String.downcase(url_repo) == String.downcase(repo) do
          {:ok, String.to_integer(number)}
        else
          :not_applicable
        end

      _other ->
        :not_applicable
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

  defp view_issue_closed_at(gh_bin, repo, number, deps) do
    args = ["issue", "view", Integer.to_string(number), "--repo", repo, "--json", "state,closedAt"]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_issue_closed_at(output)
      {:ok, {output, status}} -> {:error, {:gh_issue_view_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_view_failed, reason}}
    end
  end

  defp parse_issue_closed_at(output) do
    case Jason.decode(output) do
      {:ok, %{"closedAt" => closed_at}} when is_binary(closed_at) -> {:ok, closed_at}
      {:ok, %{"state" => state}} when is_binary(state) -> {:ok, nil}
      {:ok, other} -> {:error, {:invalid_issue_payload, other}}
      {:error, reason} -> {:error, {:gh_json_error, reason}}
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
