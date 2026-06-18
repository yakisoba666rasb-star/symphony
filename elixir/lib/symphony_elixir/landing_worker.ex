defmodule SymphonyElixir.LandingWorker do
  @moduledoc """
  Executes the Approved to Land queue after a dry-run plan has been created.

  The worker is disabled unless `landing.execute_enabled` is true. Every PR is
  revalidated with GitHub immediately before merge, then Linear is moved to the
  configured in-progress state before the merge command runs.
  """

  require Logger

  alias SymphonyElixir.{Config, GitHubCommand}

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @type execution_result :: %{
          enabled: boolean(),
          attempted: non_neg_integer(),
          merged: non_neg_integer(),
          blocked: non_neg_integer(),
          repair_requested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec execute(Config.Schema.t(), module(), [map()]) :: execution_result()
  def execute(settings, tracker, queue), do: execute(settings, tracker, queue, runtime_deps())

  @spec execute(Config.Schema.t(), module(), [map()], deps()) :: execution_result()
  def execute(settings, tracker, queue, deps) when is_list(queue) do
    result = empty_result(settings)

    cond do
      not settings.landing.enabled ->
        result

      not settings.landing.execute_enabled ->
        result

      not module_exports?(tracker, :update_issue_state, 2) ->
        Logger.warning("Skipping Approved to Land execution; #{inspect(tracker)} does not export update_issue_state/2")
        %{result | errors: result.errors + 1}

      not module_exports?(tracker, :create_comment, 2) ->
        Logger.warning("Skipping Approved to Land execution; #{inspect(tracker)} does not export create_comment/2")
        %{result | errors: result.errors + 1}

      true ->
        execute_queue(settings, tracker, queue, deps, result)
    end
  end

  def execute(settings, tracker, _queue, deps), do: execute(settings, tracker, [], deps)

  defp empty_result(settings) do
    %{
      enabled: settings.landing.enabled and settings.landing.execute_enabled,
      attempted: 0,
      merged: 0,
      blocked: 0,
      repair_requested: 0,
      skipped: 0,
      errors: 0
    }
  end

  defp execute_queue(settings, tracker, queue, deps, result) do
    selected =
      queue
      |> Enum.filter(&ready_queue_entry?/1)
      |> Enum.take(settings.landing.max_per_run)

    queue
    |> Enum.reject(&ready_queue_entry?/1)
    |> Enum.reduce(result, fn _entry, acc -> %{acc | skipped: acc.skipped + 1} end)
    |> then(fn acc ->
      Enum.reduce(selected, acc, fn entry, acc ->
        entry
        |> execute_entry(settings, tracker, deps)
        |> merge_execution_result(acc)
      end)
    end)
  end

  defp execute_entry(entry, settings, tracker, deps) do
    result = %{empty_result(settings) | attempted: 1}

    with {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, pr} <- revalidate_pr(gh_bin, entry, settings, deps) do
      land_and_merge(entry, pr, gh_bin, settings, tracker, deps, result)
    else
      {:blocked, reason} ->
        block_entry(tracker, entry, settings, reason, result)

      {:error, reason} ->
        Logger.warning("Approved to Land execution failed for #{entry_context(entry)}: #{inspect(reason)}")
        %{result | errors: 1}
    end
  end

  defp land_and_merge(entry, pr, gh_bin, settings, tracker, deps, result) do
    case move_issue_state(tracker, entry, settings.landing.in_progress_state) do
      :ok ->
        merge_after_landing(entry, pr, gh_bin, settings, tracker, deps, result)

      {:error, reason} ->
        Logger.warning("Approved to Land execution failed for #{entry_context(entry)}: #{inspect(reason)}")
        write_transition_failure_comment(tracker, entry, landing_transition_failed_comment(entry, pr, reason, settings))
        %{result | errors: 1}
    end
  end

  defp merge_after_landing(entry, pr, gh_bin, settings, tracker, deps, result) do
    case create_comment(tracker, entry, start_comment(entry, pr, settings)) do
      :ok ->
        run_merge_after_start_comment(entry, pr, gh_bin, settings, tracker, deps, result)

      {:error, reason} ->
        block_after_landing(tracker, entry, settings, {:start_comment_failed, reason}, result)
    end
  end

  defp run_merge_after_start_comment(entry, pr, gh_bin, settings, tracker, deps, result) do
    case merge_pr(gh_bin, pr, settings, deps) do
      {:ok, output} ->
        finish_success(entry, pr, output, settings, tracker, result)

      {:blocked, reason} ->
        block_entry(tracker, entry, settings, reason, result)

      {:error, reason} ->
        block_after_landing(tracker, entry, settings, {:merge_command_failed, reason}, result)
    end
  end

  defp finish_success(entry, pr, output, settings, tracker, result) do
    case create_comment(tracker, entry, success_comment(entry, pr, output, settings)) do
      :ok ->
        %{result | merged: 1}

      {:error, reason} ->
        Logger.warning("Approved to Land merged #{entry_context(entry)} but success comment failed: #{inspect(reason)}")
        %{result | merged: 1, errors: 1}
    end
  end

  defp merge_execution_result(%{} = entry_result, %{} = acc) do
    %{
      acc
      | attempted: acc.attempted + Map.get(entry_result, :attempted, 0),
        merged: acc.merged + Map.get(entry_result, :merged, 0),
        blocked: acc.blocked + Map.get(entry_result, :blocked, 0),
        repair_requested: acc.repair_requested + Map.get(entry_result, :repair_requested, 0),
        skipped: acc.skipped + Map.get(entry_result, :skipped, 0),
        errors: acc.errors + Map.get(entry_result, :errors, 0)
    }
  end

  defp ready_queue_entry?(%{} = entry) do
    Map.get(entry, :planned_action) == "merge" and
      Map.get(entry, :status) == "ready" and
      Map.get(entry, :blocker) == "none" and
      Map.get(entry, :mergeability) == "CLEAN" and
      Map.get(entry, :pr_state) == "OPEN" and
      draft_executable?(Map.get(entry, :draft)) and
      valid_string?(Map.get(entry, :issue_id)) and
      valid_pr_url?(Map.get(entry, :pr_url))
  end

  defp ready_queue_entry?(_entry), do: false

  defp draft_executable?(true), do: false
  defp draft_executable?("true"), do: false
  defp draft_executable?(_draft), do: true

  defp revalidate_pr(gh_bin, entry, settings, deps) do
    args = [
      "pr",
      "view",
      Map.fetch!(entry, :pr_url),
      "--json",
      "number,url,state,isDraft,mergeStateStatus,headRefName,headRefOid,baseRefName,reviewDecision"
    ]

    command_result =
      deps.run_command.(gh_bin, args,
        stderr_to_stdout: true,
        timeout_ms: settings.landing.command_timeout_ms
      )

    case normalize_command_result(command_result) do
      {:ok, {output, 0}} ->
        output
        |> Jason.decode()
        |> case do
          {:ok, %{} = pr} -> validate_fresh_pr(entry, pr)
          {:error, reason} -> {:error, {:invalid_pr_view_json, reason}}
        end

      {:ok, {output, status}} ->
        {:error, {:gh_pr_view_failed, status, String.trim(output)}}

      {:error, reason} ->
        {:error, {:gh_pr_view_failed, reason}}
    end
  end

  defp validate_fresh_pr(entry, pr) do
    case fresh_pr_blocker(entry, pr) do
      nil -> {:ok, pr}
      reason -> {:blocked, reason}
    end
  end

  defp fresh_pr_blocker(entry, pr) do
    [
      fn -> pr_state_blocker(pr) end,
      fn -> pr_draft_blocker(pr) end,
      fn -> pr_mergeability_blocker(pr) end,
      fn -> pr_review_decision_blocker(pr) end,
      fn -> pr_head_branch_blocker(entry, pr) end,
      fn -> pr_head_sha_blocker(entry, pr) end
    ]
    |> Enum.find_value(& &1.())
  end

  defp pr_state_blocker(pr) do
    if pr_value(pr, "state") == "OPEN", do: nil, else: "PR is no longer open: #{pr_value(pr, "state")}"
  end

  defp pr_draft_blocker(pr), do: if(pr_value(pr, "isDraft") == true, do: "PR is draft")

  defp pr_mergeability_blocker(pr) do
    if pr_value(pr, "mergeStateStatus") == "CLEAN", do: nil, else: "PR mergeability changed to #{pr_value(pr, "mergeStateStatus")}"
  end

  defp pr_review_decision_blocker(pr) do
    if pr_value(pr, "reviewDecision") == "CHANGES_REQUESTED", do: "GitHub review decision is CHANGES_REQUESTED"
  end

  defp pr_head_branch_blocker(entry, pr) do
    planned = Map.get(entry, :head_branch)
    actual = pr_value(pr, "headRefName")

    if valid_string?(planned) and actual != planned do
      "PR head branch changed from #{planned} to #{actual}"
    end
  end

  defp pr_head_sha_blocker(entry, pr) do
    planned = Map.get(entry, :head_sha)
    actual = pr_value(pr, "headRefOid")

    if valid_string?(planned) and actual != planned do
      "PR head SHA changed from #{planned} to #{actual}"
    end
  end

  defp merge_pr(gh_bin, pr, settings, deps) do
    args = [
      "pr",
      "merge",
      pr_value(pr, "url"),
      merge_flag(settings.landing.merge_method)
    ]

    command_result =
      deps.run_command.(gh_bin, args,
        stderr_to_stdout: true,
        timeout_ms: settings.landing.command_timeout_ms
      )

    case normalize_command_result(command_result) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:blocked, "GitHub merge command failed with status #{status}: #{String.trim(output)}"}
      {:error, reason} -> {:error, {:gh_pr_merge_failed, reason}}
    end
  end

  defp merge_flag("merge"), do: "--merge"
  defp merge_flag("rebase"), do: "--rebase"
  defp merge_flag(_method), do: "--squash"

  defp block_entry(tracker, entry, settings, reason, result) do
    Logger.warning("Blocking Approved to Land item #{entry_context(entry)}: #{reason}")

    case move_issue_state(tracker, entry, settings.landing.blocked_state) do
      :ok ->
        case create_comment(tracker, entry, blocked_comment(entry, reason, settings)) do
          :ok ->
            result
            |> Map.put(:blocked, 1)
            |> maybe_request_repair(tracker, entry, settings, reason)

          {:error, comment_reason} ->
            Logger.warning("Failed to comment on blocked Approved to Land item #{entry_context(entry)}: #{inspect(comment_reason)}")
            %{result | errors: 1}
        end

      {:error, blocker_reason} ->
        Logger.warning("Failed to block Approved to Land item #{entry_context(entry)}: #{inspect(blocker_reason)}")

        write_transition_failure_comment(
          tracker,
          entry,
          blocked_transition_failed_comment(entry, reason, blocker_reason, settings)
        )

        %{result | errors: 1}
    end
  end

  defp maybe_request_repair(result, _tracker, _entry, %{landing: %{repair_enabled: false}}, _reason), do: result

  defp maybe_request_repair(result, tracker, entry, settings, reason) do
    repair_state = settings.landing.repair_state

    with :ok <- move_issue_state(tracker, entry, repair_state),
         :ok <- create_comment(tracker, entry, repair_comment(entry, reason, settings)) do
      %{result | repair_requested: result.repair_requested + 1}
    else
      {:error, repair_reason} ->
        Logger.warning("Failed to request Approved to Land repair for #{entry_context(entry)}: #{inspect(repair_reason)}")
        %{result | errors: result.errors + 1}
    end
  end

  defp block_after_landing(tracker, entry, settings, reason, result) do
    Logger.warning("Blocking Approved to Land item #{entry_context(entry)} after Landing transition: #{inspect(reason)}")

    block_entry(
      tracker,
      entry,
      settings,
      "Landing execution failed before merge completion: #{format_reason(reason)}",
      result
    )
  end

  defp move_issue_state(tracker, entry, state_name) do
    case tracker.update_issue_state(Map.fetch!(entry, :issue_id), state_name) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:linear_state_update_failed, reason}}
      other -> {:error, {:linear_state_update_unexpected, other}}
    end
  end

  defp create_comment(tracker, entry, body) do
    case tracker.create_comment(Map.fetch!(entry, :issue_id), body) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:linear_comment_failed, reason}}
      other -> {:error, {:linear_comment_unexpected, other}}
    end
  end

  defp write_transition_failure_comment(tracker, entry, body) do
    case create_comment(tracker, entry, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write Approved to Land transition failure comment for #{entry_context(entry)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_comment(entry, pr, settings) do
    """
    Symphony Approved to Land execution started

    Issue: #{issue_label(entry)}
    Queue position: #{Map.get(entry, :queue_position, "unknown")} of #{Map.get(entry, :queue_total, "unknown")}
    Action: merge with #{settings.landing.merge_method}
    PR: #{pr_value(pr, "url")}
    Head: #{pr_value(pr, "headRefName")} #{pr_value(pr, "headRefOid")}
    Base: #{pr_value(pr, "baseRefName")}

    The PR was revalidated as open, non-draft, and CLEAN immediately before this action.
    """
    |> String.trim()
  end

  defp success_comment(entry, pr, output, settings) do
    """
    Symphony Approved to Land execution completed

    Issue: #{issue_label(entry)}
    Action: merged with #{settings.landing.merge_method}
    PR: #{pr_value(pr, "url")}
    GitHub output: #{blank_fallback(output, "merge command completed")}

    Done sync will move the Linear issue to Done after merged PR evidence is observed.
    """
    |> String.trim()
  end

  defp landing_transition_failed_comment(entry, pr, reason, settings) do
    """
    Symphony Approved to Land execution could not start

    Issue: #{issue_label(entry)}
    PR: #{pr_value(pr, "url")}
    Target state: #{settings.landing.in_progress_state}
    Reason: #{format_reason(reason)}

    No merge was attempted. Create or configure the Linear workflow state, then move the issue back to #{settings.landing.approval_state}.
    """
    |> String.trim()
  end

  defp blocked_comment(entry, reason, settings) do
    """
    Symphony Approved to Land execution blocked

    Issue: #{issue_label(entry)}
    Planned action: #{Map.get(entry, :planned_action, "unknown")}
    PR: #{Map.get(entry, :pr_url, "unknown")}
    Reason: #{reason}

    The issue was moved to #{settings.landing.blocked_state}. Move it back to #{settings.landing.approval_state} after resolving the blocker.
    """
    |> String.trim()
  end

  defp blocked_transition_failed_comment(entry, original_reason, transition_reason, settings) do
    """
    Symphony Approved to Land execution could not mark the item blocked

    Issue: #{issue_label(entry)}
    Planned action: #{Map.get(entry, :planned_action, "unknown")}
    PR: #{Map.get(entry, :pr_url, "unknown")}
    Original blocker: #{original_reason}
    Target blocked state: #{settings.landing.blocked_state}
    State transition error: #{format_reason(transition_reason)}

    No merge was attempted after this blocker. Create or configure the Linear workflow state, then move the issue back to #{settings.landing.approval_state} when it is ready for another landing attempt.
    """
    |> String.trim()
  end

  defp repair_comment(entry, reason, settings) do
    """
    Symphony Approved to Land repair requested

    Issue: #{issue_label(entry)}
    PR: #{Map.get(entry, :pr_url, "unknown")}
    Reason: #{reason}

    The issue was moved from #{settings.landing.blocked_state} to #{settings.landing.repair_state} so the normal implementation agent can repair the PR branch. Resolve the blocker, update the existing PR when possible, and return the issue to #{settings.tracker.review_state}. A human should move it back to #{settings.landing.approval_state} after re-review.

    The repair agent must not merge the PR.
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &GitHubCommand.run_system_cmd/3
    }
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status), do: {:ok, {output, status}}
  defp normalize_command_result(result), do: result

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp module_exports?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end

  defp module_exports?(_module, _function_name, _arity), do: false

  defp pr_value(pr, key), do: Map.get(pr, key) || Map.get(pr, atom_key(key)) || "unknown"

  defp atom_key("isDraft"), do: :isDraft
  defp atom_key("mergeStateStatus"), do: :mergeStateStatus
  defp atom_key("headRefName"), do: :headRefName
  defp atom_key("headRefOid"), do: :headRefOid
  defp atom_key("baseRefName"), do: :baseRefName
  defp atom_key("reviewDecision"), do: :reviewDecision
  defp atom_key("state"), do: :state
  defp atom_key("url"), do: :url
  defp atom_key(_key), do: nil

  defp valid_pr_url?(value) when is_binary(value), do: String.starts_with?(value, "https://github.com/") and String.contains?(value, "/pull/")
  defp valid_pr_url?(_value), do: false

  defp valid_string?(value) when is_binary(value), do: String.trim(value) not in ["", "unknown"]
  defp valid_string?(_value), do: false

  defp blank_fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: String.trim(value)
  end

  defp format_reason(reason), do: inspect(reason)

  defp issue_label(entry), do: Map.get(entry, :issue_identifier) || Map.get(entry, :issue_id) || "unknown"

  defp entry_context(entry), do: "issue=#{issue_label(entry)} pr=#{Map.get(entry, :pr_url, "unknown")}"
end
