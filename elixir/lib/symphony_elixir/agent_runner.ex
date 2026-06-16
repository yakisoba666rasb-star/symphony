defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, GitHubPrLookup, Linear.Issue, PromptBuilder, SSH, Tracker, Workspace}

  @ignored_dirty_status_pathspecs [
    ":!.symphony-review-verdict.json",
    ":!.symphony-review-verdict-*.json"
  ]

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, {:max_turns_reached_active_issue, _issue_id} = reason} ->
        Logger.warning("Agent run stopped unfinished for #{issue_context(issue)}: #{inspect(reason)}")
        exit(reason)

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    workspace_opts =
      if Keyword.get(opts, :allow_dirty_existing_workspace, false) do
        [allow_dirty_existing_workspace: true, return_metadata: true]
      else
        [return_metadata: true]
      end

    case Workspace.create_for_issue(issue, worker_host, workspace_opts) do
      {:ok, workspace, workspace_metadata} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, workspace_metadata)
        dirty_resume? = Keyword.get(workspace_opts, :allow_dirty_existing_workspace, false) and workspace_has_changes?(workspace, worker_host)

        try do
          with :ok <- maybe_run_before_run_hook(workspace, issue, worker_host, dirty_resume?) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_run_before_run_hook(workspace, issue, worker_host, true) do
    Logger.info("Skipping before_run hook for dirty workspace resume #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
    :ok
  end

  defp maybe_run_before_run_hook(workspace, issue, worker_host, false) do
    Workspace.run_before_run_hook(workspace, issue, worker_host)
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, metadata)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) and is_map(metadata) do
    message =
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
      |> put_worker_runtime_quarantine(metadata)

    send(recipient, message)

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _metadata), do: :ok

  defp put_worker_runtime_quarantine(message, %{quarantined_workspace: quarantine})
       when is_map(quarantine) do
    put_in(message, [Access.elem(1), :workspace_quarantine], quarantine)
  end

  defp put_worker_runtime_quarantine(message, _metadata), do: message

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      if workspace_has_changes?(workspace, app_session.worker_host) do
        Logger.info("Workspace has uncommitted changes after normal turn for #{issue_context(issue)}; stopping for runtime PR handoff")
        :ok
      else
        continue_after_clean_turn(
          app_session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number,
          max_turns
        )
      end
    end
  end

  defp continue_after_clean_turn(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    case ready_handoff_pr_after_clean_turn(workspace, issue) do
      {:ok, %{} = pr} ->
        Logger.info(
          "Ready PR already discoverable for #{issue_context(issue)} after clean turn; stopping for runtime review handoff " <>
            "pr=#{pr_url(pr)} branch=#{inspect(issue.branch_name)} source=#{inspect(pr_lookup_source(pr))}"
        )

        :ok

      {:ok, nil} ->
        continue_after_clean_turn_issue_state(
          app_session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number,
          max_turns
        )

      {:error, reason} ->
        Logger.warning("Ready PR handoff lookup failed for #{issue_context(issue)} after clean turn; continuing active issue check reason=#{inspect(reason)}")

        continue_after_clean_turn_issue_state(
          app_session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number,
          max_turns
        )
    end
  end

  defp continue_after_clean_turn_issue_state(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          app_session,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning unfinished outcome to orchestrator")

        {:error, {:max_turns_reached_active_issue, refreshed_issue.id}}

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ready_handoff_pr_after_clean_turn(workspace, %Issue{branch_name: branch_name} = issue)
       when is_binary(workspace) and is_binary(branch_name) do
    case String.trim(branch_name) do
      "" ->
        {:ok, nil}

      branch_name ->
        lookup_ready_handoff_pr_after_clean_turn(workspace, branch_name, issue)
    end
  end

  defp ready_handoff_pr_after_clean_turn(_workspace, _issue), do: {:ok, nil}

  defp lookup_ready_handoff_pr_after_clean_turn(workspace, branch_name, issue) do
    lookup_module = Application.get_env(:symphony_elixir, :github_pr_lookup, GitHubPrLookup)
    attachment_urls = issue_attachment_urls(issue)

    lookup_result =
      if Code.ensure_loaded?(lookup_module) and function_exported?(lookup_module, :lookup_workspace_handoff_pr, 3) do
        lookup_module.lookup_workspace_handoff_pr(workspace, branch_name, attachment_urls)
      else
        lookup_module.lookup_workspace_head(workspace, branch_name)
      end

    normalize_ready_handoff_pr_after_clean_turn(lookup_result, issue)
  end

  defp normalize_ready_handoff_pr_after_clean_turn({:ok, %{} = pr}, issue) do
    if ready_handoff_pr?(pr) do
      {:ok, pr}
    else
      Logger.info(
        "PR found for #{issue_context(issue)} after clean turn but rejected for ready handoff " <>
          "pr=#{pr_url(pr)} state=#{inspect(pr_state(pr))} draft=#{inspect(pr_draft?(pr))}"
      )

      {:ok, nil}
    end
  end

  defp normalize_ready_handoff_pr_after_clean_turn(other, _issue), do: other

  defp issue_attachment_urls(%Issue{attachment_urls: attachment_urls}) when is_list(attachment_urls),
    do: attachment_urls

  defp issue_attachment_urls(_issue), do: []

  defp ready_handoff_pr?(pr) do
    pr_state(pr) == "OPEN" and pr_draft?(pr) != true
  end

  defp pr_state(%{"state" => state}) when is_binary(state), do: String.upcase(state)
  defp pr_state(%{state: state}) when is_binary(state), do: String.upcase(state)
  defp pr_state(_pr), do: nil

  defp pr_draft?(%{"isDraft" => draft}), do: draft
  defp pr_draft?(%{isDraft: draft}), do: draft
  defp pr_draft?(_pr), do: nil

  defp pr_url(%{"url" => url}) when is_binary(url), do: url
  defp pr_url(%{url: url}) when is_binary(url), do: url
  defp pr_url(_pr), do: "unknown"

  defp pr_lookup_source(%{"__symphonyLookupSource" => source}), do: source
  defp pr_lookup_source(%{__symphonyLookupSource: source}), do: source
  defp pr_lookup_source(_pr), do: nil

  defp workspace_has_changes?(workspace, nil) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "status", "--porcelain", "--"] ++ @ignored_dirty_status_pathspecs, stderr_to_stdout: true) do
      {"", 0} ->
        false

      {_status, 0} ->
        true

      {output, status} ->
        Logger.warning("Could not inspect workspace dirty status for #{workspace}: git exited #{status}: #{String.trim(output)}")
        false
    end
  rescue
    exception ->
      Logger.warning("Could not inspect workspace dirty status for #{workspace}: #{Exception.message(exception)}")
      false
  end

  defp workspace_has_changes?(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    case remote_workspace_status(workspace, worker_host) do
      {:ok, ""} ->
        false

      {:ok, _status} ->
        true

      {:error, reason} ->
        Logger.warning("Could not inspect remote workspace dirty status for #{workspace} worker_host=#{worker_host_for_log(worker_host)}: #{inspect(reason)}; treating as dirty")

        true
    end
  end

  defp remote_workspace_status(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "cd \"$workspace\"",
        "git status --porcelain -- ':!.symphony-review-verdict.json' ':!.symphony-review-verdict-*.json'"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:remote_git_status_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:remote_command_timeout, timeout_ms}}
    end
  end

  defp remote_shell_assign(variable_name, raw_value)
       when is_binary(variable_name) and is_binary(raw_value) do
    [
      "#{variable_name}=#{shell_escape(raw_value)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
