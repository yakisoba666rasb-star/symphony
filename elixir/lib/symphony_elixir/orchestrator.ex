defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    GitHubIssue,
    GitHubReviewStatus,
    HermesDelegation,
    LandingPlanner,
    LandingWorker,
    RepositoryResolver,
    RepositoryRoutes,
    RetryPolicy,
    ReviewRunner,
    StatusDashboard,
    Tracker,
    Workspace,
    ZeroTouchEvidence
  }

  alias SymphonyElixir.Linear.Issue

  @handoff_pr_lookup_refresh_delay_ms 500
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @landing_blocking_labels [
    "landing-blocked",
    "landing-conflict",
    "landing-checks-failing",
    "landing-needs-review",
    "landing-draft",
    "landing-stale-pr"
  ]
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      unroutable: [],
      retry_attempts: %{},
      pending_review_handoffs: %{},
      review_rework_rounds: %{},
      github_intake_attempts: %{},
      github_intake_task: nil,
      done_source_github_issue_closes: MapSet.new(),
      last_github_intake_sync_ms: nil,
      last_done_sync_ms: nil,
      last_landing_plan_ms: nil,
      landing_queue: [],
      last_review_rework_sync_ms: nil,
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_dirty_workspace_cleanup()
    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = preserve_orchestrator_state(state, "tick runtime config refresh", &refresh_runtime_config/1)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = preserve_orchestrator_state(state, "tick runtime config refresh", &refresh_runtime_config/1)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state =
      preserve_orchestrator_state(state, "poll cycle", fn state ->
        state
        |> refresh_runtime_config()
        |> maybe_dispatch()
      end)

    state = finish_poll_cycle(state)

    {:noreply, state}
  end

  def handle_info({ref, {result, attempts}}, %{github_intake_task: %Task{ref: ref}} = state)
      when is_reference(ref) and is_map(attempts) do
    Process.demonitor(ref, [:flush])
    log_github_issue_intake_result(result)

    state = %{
      state
      | github_intake_attempts: attempts,
        github_intake_task: nil,
        last_github_intake_sync_ms: System.monotonic_time(:millisecond)
    }

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{github_intake_task: %Task{ref: ref}} = state)
      when is_reference(ref) do
    Logger.warning("GitHub issue intake sync task exited before completion: #{inspect(reason)}")

    state = %{state | github_intake_task: nil}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, handle_pending_review_handoff_down(state, ref, reason)}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        comment_on_quarantined_workspace(issue_id, updated_running_entry, runtime_info[:workspace_quarantine])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        state = maybe_block_repeated_fingerprint(state, issue_id, updated_running_entry)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({review_ref, result}, %{pending_review_handoffs: pending} = state)
      when is_reference(review_ref) do
    case Map.pop(pending, review_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {metadata, pending} ->
        Process.demonitor(review_ref, [:flush])

        state =
          state
          |> Map.put(:pending_review_handoffs, pending)
          |> finish_pending_review_handoff(metadata, result)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp finish_poll_cycle(%State{} = state) do
    state =
      state
      |> schedule_tick(state.poll_interval_ms)
      |> Map.put(:poll_check_in_progress, false)

    notify_dashboard()
    state
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      case branch_name_and_workspace(running_entry) do
        {:ok, branch_name, workspace_path} ->
          handle_normal_completion_with_pr_check(
            state,
            issue_id,
            running_entry,
            session_id,
            branch_name,
            workspace_path
          )

        :missing ->
          handle_normal_completion_without_branch(state, issue_id, running_entry, session_id)
      end
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      max_turns_reached_active_issue?(reason) ->
        block_max_turns_agent_down(state, issue_id, running_entry, session_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp handle_normal_completion_without_branch(state, issue_id, running_entry, session_id) do
    if has_workspace_path?(running_entry) do
      error = "no branch name available for GitHub PR lookup"

      Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

      block_issue_from_entry(state, issue_id, running_entry, error)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_normal_completion_with_pr_check(
         state,
         issue_id,
         running_entry,
         session_id,
         branch_name,
         workspace_path
       ) do
    case lookup_pr_for_handoff(workspace_path, running_entry, branch_name) do
      {:ok, pr} when is_map(pr) ->
        move_issue_to_review_after_pr_discovery(state, issue_id, running_entry, session_id, pr)

      {:ok, nil} ->
        error =
          "no GitHub PR found for branch #{branch_name} or linked PR attachments; agent-owned PR is required before In Review handoff"

        retry_handoff_pr_lookup_after_issue_refresh_or_block(
          state,
          issue_id,
          running_entry,
          session_id,
          branch_name,
          workspace_path,
          error
        )

      {:error, reason} ->
        error = "GitHub PR lookup failed for branch #{branch_name}: #{inspect(reason)}"

        retry_handoff_pr_lookup_after_issue_refresh_or_block(
          state,
          issue_id,
          running_entry,
          session_id,
          branch_name,
          workspace_path,
          error
        )

      _other ->
        error = "GitHub PR lookup returned unexpected result for branch #{branch_name}"

        Logger.error(
          "Unexpected GitHub PR lookup result; skipping Linear issue refresh before handoff block: issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}"
        )

        block_issue_from_entry(state, issue_id, running_entry, error)
    end
  end

  defp retry_handoff_pr_lookup_after_issue_refresh_or_block(
         state,
         issue_id,
         running_entry,
         session_id,
         branch_name,
         workspace_path,
         error
       ) do
    policy = Config.retry_policy(:handoff_pr_discovery)

    case retry_handoff_pr_lookup_after_issue_refresh(running_entry, branch_name, workspace_path, policy) do
      {:ok, pr, refreshed_entry, attempt} ->
        Logger.info(
          "PR discovered after refreshing Linear issue before handoff block: " <>
            "issue_id=#{issue_id} issue_identifier=#{Map.get(refreshed_entry, :identifier)} " <>
            "session_id=#{session_id} attempt=#{attempt}"
        )

        move_issue_to_review_after_pr_discovery(state, issue_id, refreshed_entry, session_id, pr)

      {:error, refreshed_entry, attempt, retry_error} ->
        terminal_error = RetryPolicy.terminal_reason(policy, attempt, retry_error || error)

        Logger.warning(
          "Agent task blocked for issue_id=#{issue_id} " <>
            "issue_identifier=#{Map.get(refreshed_entry, :identifier)} session_id=#{session_id}: " <>
            terminal_error
        )

        block_issue_from_entry(state, issue_id, refreshed_entry, terminal_error)
    end
  end

  defp retry_handoff_pr_lookup_after_issue_refresh(running_entry, branch_name, workspace_path, policy) do
    do_retry_handoff_pr_lookup_after_issue_refresh(
      running_entry,
      branch_name,
      workspace_path,
      policy,
      RetryPolicy.reset_on_progress(%{}, handoff_pr_evidence(running_entry)),
      nil
    )
  end

  defp do_retry_handoff_pr_lookup_after_issue_refresh(
         running_entry,
         branch_name,
         workspace_path,
         policy,
         attempt_state,
         last_error
       ) do
    next_attempt = Map.get(attempt_state, :attempts, 0) + 1

    if RetryPolicy.allow_attempt?(next_attempt, policy) do
      if next_attempt == 1 do
        Process.sleep(@handoff_pr_lookup_refresh_delay_ms)
      end

      refreshed_entry = refresh_running_entry_issue_for_handoff_retry(running_entry)

      case lookup_pr_for_handoff(workspace_path, refreshed_entry, branch_name) do
        {:ok, pr} when is_map(pr) ->
          {:ok, pr, refreshed_entry, next_attempt}

        miss ->
          retry_error = handoff_pr_lookup_retry_error(branch_name, miss, last_error)

          next_state =
            attempt_state
            |> Map.put(:attempts, next_attempt)
            |> RetryPolicy.reset_on_progress(handoff_pr_evidence(refreshed_entry))

          do_retry_handoff_pr_lookup_after_issue_refresh(
            refreshed_entry,
            branch_name,
            workspace_path,
            policy,
            next_state,
            retry_error
          )
      end
    else
      {running_entry, Map.get(attempt_state, :attempts, 0), last_error}
      |> then(fn {entry, attempts, retry_error} -> {:error, entry, attempts + 1, retry_error} end)
    end
  end

  defp handoff_pr_lookup_retry_error(branch_name, {:ok, nil}, _last_error) do
    "no GitHub PR found for branch #{branch_name} or linked PR attachments; agent-owned PR is required before In Review handoff"
  end

  defp handoff_pr_lookup_retry_error(branch_name, {:error, reason}, _last_error) do
    "GitHub PR lookup failed for branch #{branch_name}: #{inspect(reason)}"
  end

  defp handoff_pr_lookup_retry_error(branch_name, other, _last_error) do
    "GitHub PR lookup returned unexpected result for branch #{branch_name}: #{inspect(other)}"
  end

  defp refresh_running_entry_issue_for_handoff_retry(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :issue) do
      %Issue{id: issue_id} when is_binary(issue_id) ->
        case tracker_module().fetch_issue_states_by_ids([issue_id]) do
          {:ok, [%Issue{} = refreshed_issue | _]} ->
            refresh_running_entry_issue(running_entry, refreshed_issue)

          _miss_or_error ->
            running_entry
        end

      _other ->
        running_entry
    end
  rescue
    _exception ->
      running_entry
  end

  defp refresh_running_entry_issue_for_handoff_retry(running_entry), do: running_entry

  defp tracker_module do
    Application.get_env(:symphony_elixir, :tracker_module, Tracker)
  end

  defp github_review_status_module do
    Application.get_env(:symphony_elixir, :github_review_status, GitHubReviewStatus)
  end

  defp agent_runner_module do
    Application.get_env(:symphony_elixir, :agent_runner, AgentRunner)
  end

  defp branch_name_and_workspace(%{branch_name: branch_name, workspace_path: workspace_path})
       when is_binary(branch_name) and is_binary(workspace_path),
       do: {:ok, branch_name, workspace_path}

  defp branch_name_and_workspace(%{issue: %Issue{branch_name: branch_name}, workspace_path: workspace_path})
       when is_binary(branch_name) and is_binary(workspace_path),
       do: {:ok, branch_name, workspace_path}

  defp branch_name_and_workspace(_running_entry), do: :missing

  defp has_workspace_path?(%{workspace_path: workspace_path}) when is_binary(workspace_path) do
    String.trim(workspace_path) != ""
  end

  defp has_workspace_path?(_running_entry), do: false

  defp lookup_pr_for_handoff(workspace_path, running_entry, branch_name)
       when is_binary(workspace_path) and is_binary(branch_name) do
    lookup_module = github_pr_lookup_module()
    issue = Map.get(running_entry, :issue)
    attachment_urls = issue_attachment_urls(issue)

    if module_exports?(lookup_module, :lookup_workspace_handoff_pr, 3) do
      lookup_module.lookup_workspace_handoff_pr(workspace_path, branch_name, attachment_urls)
    else
      lookup_module.lookup_workspace_head(workspace_path, branch_name)
    end
  end

  defp lookup_pr_for_handoff(_workspace_path, _running_entry, _branch_name) do
    {:error, :invalid_pr_lookup_input}
  end

  defp issue_attachment_urls(%Issue{attachment_urls: attachment_urls}) when is_list(attachment_urls),
    do: attachment_urls

  defp issue_attachment_urls(_issue), do: []

  defp github_pr_lookup_module do
    Application.get_env(:symphony_elixir, :github_pr_lookup, SymphonyElixir.GitHubPrLookup)
  end

  defp github_issue_module do
    Application.get_env(:symphony_elixir, :github_issue, GitHubIssue)
  end

  defp landing_worker_module do
    Application.get_env(:symphony_elixir, :landing_worker, LandingWorker)
  end

  defp github_issue_intake_adapter do
    tracker = tracker_module()

    if module_exports?(tracker, :adapter, 0) do
      tracker.adapter()
    else
      tracker
    end
  end

  defp zero_touch_evidence_module do
    Application.get_env(:symphony_elixir, :zero_touch_evidence, ZeroTouchEvidence)
  end

  defp module_exports?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end

  defp module_exports?(_module, _function_name, _arity), do: false

  defp review_runner_module do
    Application.get_env(:symphony_elixir, :review_runner, ReviewRunner)
  end

  defp max_turns_reached_active_issue?({:max_turns_reached_active_issue, _issue_id}), do: true
  defp max_turns_reached_active_issue?(_reason), do: false

  defp block_max_turns_agent_down(state, issue_id, running_entry, session_id) do
    case branch_name_and_workspace(running_entry) do
      {:ok, branch_name, workspace_path} ->
        case lookup_pr_for_handoff(workspace_path, running_entry, branch_name) do
          {:ok, pr} when is_map(pr) ->
            move_issue_to_review_after_pr_discovery(state, issue_id, running_entry, session_id, pr)

          {:ok, nil} ->
            schedule_max_turns_continuation(state, issue_id, running_entry, session_id, nil)

          {:error, reason} ->
            schedule_max_turns_continuation(state, issue_id, running_entry, session_id, reason)

          other ->
            schedule_max_turns_continuation(state, issue_id, running_entry, session_id, {:unexpected_pr_lookup, other})
        end

      :missing ->
        schedule_max_turns_continuation(state, issue_id, running_entry, session_id, :missing_branch_or_workspace)
    end
  end

  defp move_issue_to_review_after_pr_discovery(state, issue_id, running_entry, session_id, pr) do
    _pr_number = pr["number"] || pr[:number]
    _pr_url = pr["url"] || pr[:url]

    start_review_handoff_task(state, :normal, issue_id, running_entry, session_id, pr, nil)
  end

  defp start_review_handoff_task(
         %State{} = state,
         mode,
         issue_id,
         running_entry,
         session_id,
         pr,
         issue,
         opts \\ []
       )
       when mode in [:normal, :premature] do
    if pending_review_handoff_for_issue?(state, issue_id) do
      issue_identifier = review_handoff_identifier(running_entry, issue) || issue_id

      Logger.info(
        "Skipping duplicate review handoff start for issue_id=#{issue_id} issue_identifier=#{issue_identifier} " <>
          "mode=#{mode} pr=#{pr_url(pr)}; " <>
          "a review handoff is already pending"
      )

      state
    else
      do_start_review_handoff_task(state, mode, issue_id, running_entry, session_id, pr, issue, opts)
    end
  end

  defp do_start_review_handoff_task(%State{} = state, mode, issue_id, running_entry, session_id, pr, issue, opts) do
    review_runner = review_runner_module()
    tracker = tracker_module()
    max_review_fix_loops = Config.max_review_fix_loops()

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        review_pr_before_handoff(running_entry, pr, review_runner, max_review_fix_loops)
      end)

    pending_review_handoff = %{
      mode: mode,
      issue_id: issue_id,
      running_entry: running_entry,
      session_id: session_id,
      pr: pr,
      issue: issue,
      tracker: tracker,
      release_claim_on_completion: Keyword.get(opts, :release_claim_on_completion, false),
      pid: task.pid,
      started_at: DateTime.utc_now()
    }

    issue_identifier = review_handoff_identifier(running_entry, issue) || issue_id

    Logger.info(
      "Started async review handoff for issue_id=#{issue_id} issue_identifier=#{issue_identifier} " <>
        "session_id=#{session_id} pr=#{pr_url(pr)} review_pid=#{inspect(task.pid)}"
    )

    %{
      state
      | pending_review_handoffs: Map.put(state.pending_review_handoffs, task.ref, pending_review_handoff)
    }
  end

  defp handle_pending_review_handoff_down(%{pending_review_handoffs: pending} = state, ref, :normal)
       when is_reference(ref) do
    if Map.has_key?(pending, ref) do
      Logger.debug("Review handoff task exited normally before result was handled; waiting for result ref=#{inspect(ref)}")
    end

    state
  end

  defp handle_pending_review_handoff_down(%{pending_review_handoffs: pending} = state, ref, reason)
       when is_reference(ref) do
    case Map.pop(pending, ref) do
      {nil, _pending} ->
        state

      {metadata, pending} ->
        state
        |> Map.put(:pending_review_handoffs, pending)
        |> finish_pending_review_handoff(metadata, {:error, {:review_task_down, reason}})
    end
  end

  defp handle_pending_review_handoff_down(state, _ref, _reason), do: state

  defp finish_pending_review_handoff(
         %State{} = state,
         %{mode: :normal, issue_id: issue_id, running_entry: running_entry, session_id: session_id, pr: pr} =
           metadata,
         result
       ) do
    tracker = Map.get(metadata, :tracker, tracker_module())

    case result do
      {:ok, verdict} ->
        warn_on_approved_review_handoff_comment(issue_id, running_entry, pr, verdict, tracker)

        Logger.info(
          "Review loop approved-equivalent for issue_id=#{issue_id} " <>
            "issue_identifier=#{Map.get(running_entry, :identifier, issue_id)} session_id=#{session_id} " <>
            "pr=#{pr_url(pr)} verdict=#{inspect(verdict)}"
        )

        state
        |> move_issue_to_review_after_approval(issue_id, running_entry, session_id, tracker)
        |> maybe_release_completed_review_handoff_claim(issue_id, metadata)

      {:error, reason} ->
        error =
          review_handoff_terminal_error("review loop did not approve PR before In Review handoff: #{inspect(reason)}")

        Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")
        block_issue_from_entry(state, issue_id, running_entry, error)
    end
  end

  defp finish_pending_review_handoff(
         %State{} = state,
         %{mode: :premature, issue: issue, running_entry: running_entry, session_id: session_id, pr: pr} =
           metadata,
         result
       ) do
    tracker = Map.get(metadata, :tracker, tracker_module())

    case result do
      {:ok, verdict} ->
        warn_on_approved_review_handoff_comment(issue.id, running_entry, pr, verdict, tracker)

        Logger.info(
          "Review loop approved-equivalent for premature review handoff issue_id=#{issue.id} " <>
            "issue_identifier=#{issue.identifier} session_id=#{session_id} pr=#{pr_url(pr)} " <>
            "verdict=#{inspect(verdict)}"
        )

        move_issue_to_review_after_approval(state, issue.id, running_entry, session_id, tracker)

      {:error, reason} ->
        error =
          review_handoff_terminal_error("review loop did not approve PR before In Review handoff: #{inspect(reason)}")

        Logger.warning("Premature review handoff blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")
        stop_and_block_review_handoff_issue(state, issue, running_entry, error, tracker)
    end
  end

  defp review_handoff_terminal_error(error) do
    policy = Config.retry_policy(:review_handoff)
    attempt = max(policy.max_attempts, 1)
    RetryPolicy.terminal_reason(policy, attempt, error)
  end

  defp maybe_release_completed_review_handoff_claim(%State{} = state, issue_id, %{
         release_claim_on_completion: true
       }) do
    release_completed_blocked_issue(state, issue_id)
  end

  defp maybe_release_completed_review_handoff_claim(%State{} = state, _issue_id, _metadata), do: state

  defp warn_on_approved_review_handoff_comment(issue_id, running_entry, pr, verdict, tracker) do
    case comment_on_approved_review_handoff(issue_id, running_entry, pr, verdict, tracker) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Approved review handoff comment failed for issue_id=#{issue_id} " <>
            "issue_identifier=#{Map.get(running_entry, :identifier)} pr=#{pr_url(pr)} reason=#{inspect(reason)}; continuing handoff"
        )

        :ok
    end
  end

  defp comment_on_approved_review_handoff(issue_id, running_entry, pr, verdict, tracker)
       when is_binary(issue_id) do
    body = approved_review_handoff_comment(running_entry, pr, verdict)

    try do
      case tracker.create_comment(issue_id, body) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, {:approved_review_comment_failed, reason}}

        other ->
          {:error, {:approved_review_comment_failed, other}}
      end
    rescue
      exception ->
        {:error, {:approved_review_comment_failed, Exception.message(exception)}}
    end
  end

  defp comment_on_approved_review_handoff(_issue_id, _running_entry, _pr, _verdict, _tracker), do: :ok

  defp approved_review_handoff_comment(running_entry, pr, verdict) do
    """
    Symphony automated review decision: approve-equivalent.

    Issue: #{Map.get(running_entry, :identifier, "issue")}
    PR: #{pr_url(pr)}
    #{handoff_pr_resolution_note(running_entry, pr)}

    Review loop result:
    - blocking findings: #{format_review_items(verdict_value(verdict, :blocking_findings))}
    - required tests checked/requested: #{format_review_items(verdict_value(verdict, :tests_required))}
    - residual risk: #{blank_to_none(verdict_value(verdict, :residual_risk))}

    Merge judgment: ready for human final merge decision after required GitHub checks are green. The runtime will not approve on GitHub and will not merge automatically.
    """
    |> String.trim()
  end

  defp pr_url(%{"url" => url}) when is_binary(url), do: url
  defp pr_url(%{url: url}) when is_binary(url), do: url
  defp pr_url(_pr), do: "unknown"

  defp handoff_pr_resolution_note(running_entry, %{"__symphonyLookupSource" => "linked_pull_request"} = pr) do
    """

    PR resolution:
    - source: linked GitHub PR attachment
    - expected Linear branch: #{lookup_expected_branch(pr, running_entry)}
    - actual PR branch: #{lookup_actual_branch(pr)}
    """
    |> String.trim_trailing()
  end

  defp handoff_pr_resolution_note(_running_entry, _pr), do: ""

  defp lookup_expected_branch(%{"__symphonyExpectedBranch" => branch}, _running_entry) when is_binary(branch),
    do: branch

  defp lookup_expected_branch(_pr, %{issue: %Issue{branch_name: branch}}) when is_binary(branch),
    do: branch

  defp lookup_expected_branch(_pr, _running_entry), do: "unknown"

  defp lookup_actual_branch(%{"headRefName" => branch}) when is_binary(branch), do: branch
  defp lookup_actual_branch(_pr), do: "unknown"

  defp verdict_value(verdict, key) when is_map(verdict), do: Map.get(verdict, key) || Map.get(verdict, Atom.to_string(key))
  defp verdict_value(_verdict, _key), do: nil

  defp format_review_items(items) when is_list(items) do
    case Enum.map(items, &review_value_to_string/1) |> Enum.reject(&(&1 == "")) do
      [] -> "none"
      values -> Enum.join(values, "; ")
    end
  end

  defp format_review_items(nil), do: "none"
  defp format_review_items(item), do: review_value_to_string(item)

  defp blank_to_none(nil), do: "none"
  defp blank_to_none(""), do: "none"

  defp blank_to_none(value) do
    case review_value_to_string(value) do
      "" -> "none"
      text -> text
    end
  end

  defp review_value_to_string(nil), do: ""
  defp review_value_to_string(value) when is_binary(value), do: value
  defp review_value_to_string(value) when is_atom(value), do: to_string(value)
  defp review_value_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp review_value_to_string(value) when is_float(value), do: Float.to_string(value)
  defp review_value_to_string(%{} = value), do: review_map_to_string(value)
  defp review_value_to_string(value) when is_list(value), do: format_review_items(value)
  defp review_value_to_string(value), do: inspect(value)

  defp review_map_to_string(value) do
    location =
      [Map.get(value, "file") || Map.get(value, :file), Map.get(value, "line") || Map.get(value, :line)]
      |> Enum.map(&review_value_to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(":")

    command = first_review_map_value(value, ["command", :command])
    result = first_review_map_value(value, ["result", :result])

    summary =
      first_review_map_value(value, [
        "issue",
        :issue,
        "message",
        :message,
        "note",
        :note,
        "title",
        :title,
        "description",
        :description,
        "rationale",
        :rationale,
        "outcome",
        :outcome
      ]) ||
        command_result_summary(command, result) ||
        inspect(value)

    case {location, summary} do
      {"", ""} -> inspect(value)
      {"", text} -> text
      {place, ""} -> place
      {place, text} -> "#{place} - #{text}"
    end
  end

  defp first_review_map_value(value, keys) do
    keys
    |> Enum.map(&Map.get(value, &1))
    |> Enum.map(&review_value_to_string/1)
    |> Enum.find(&(&1 != ""))
  end

  defp command_result_summary(nil, nil), do: nil
  defp command_result_summary(nil, result), do: result
  defp command_result_summary(command, nil), do: command
  defp command_result_summary(command, result), do: "#{command} (#{result})"

  defp review_pr_before_handoff(running_entry, pr, review_runner, max_review_fix_loops) do
    case Map.get(running_entry, :workspace_path) do
      workspace_path when is_binary(workspace_path) ->
        review_opts = [
          max_review_fix_loops: max_review_fix_loops
        ]

        review_runner.run_loop(
          workspace_path,
          issue_for_review(running_entry),
          pr,
          review_opts
        )

      _other ->
        {:error, :missing_workspace_path_for_review_loop}
    end
  end

  defp issue_for_review(%{issue: %Issue{} = issue}), do: issue

  defp issue_for_review(running_entry) when is_map(running_entry) do
    %Issue{
      id: Map.get(running_entry, :issue_id),
      identifier: Map.get(running_entry, :identifier),
      title: Map.get(running_entry, :identifier, "Automated changes")
    }
  end

  defp move_issue_to_review_after_approval(state, issue_id, running_entry, session_id, tracker) do
    target_state = Config.review_handoff_state()

    case tracker.update_issue_state(issue_id, target_state) do
      :ok ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; issue moved to #{target_state}")

        state
        |> complete_issue(issue_id)

      {:error, reason} ->
        error = "failed to move issue to #{target_state} after PR discovery: #{inspect(reason)}"
        Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")
        block_issue_from_entry(state, issue_id, running_entry, error)

      other ->
        error = "failed to move issue to #{target_state} after PR discovery: #{inspect(other)}"
        Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")
        block_issue_from_entry(state, issue_id, running_entry, error)
    end
  end

  defp schedule_max_turns_continuation(state, issue_id, running_entry, session_id, reason) do
    next_continuation_count = next_continuation_count_from_running(running_entry)
    policy = Config.retry_policy(:max_turn_continuation)
    max_continuations = policy.max_attempts

    if RetryPolicy.allow_attempt?(next_continuation_count, policy) do
      error = "agent.max_turns reached while Linear issue stayed active; scheduling continuation"
      error = if is_nil(reason), do: error, else: "#{error}: #{inspect(reason)}"

      Logger.warning("Agent task reached max turns for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, next_retry_attempt_from_running(running_entry), %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        policy_context: :max_turn_continuation,
        continuation_count: next_continuation_count,
        error: error,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    else
      error = "agent.max_turns continuation limit reached (#{max_continuations}); blocking active issue"
      error = if is_nil(reason), do: error, else: "#{error}: #{inspect(reason)}"

      Logger.warning("Agent task blocked after max-turn continuations for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

      block_issue_from_entry(state, issue_id, running_entry, error)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_active_open_pr_handoffs()
      |> reconcile_review_rework_requests()
      |> maybe_plan_approved_landings()
      |> maybe_sync_merged_linked_pull_requests_to_done()

    with :ok <- Config.validate!(),
         state <- maybe_sync_github_issue_intake(state),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         issues <- auto_assign_missing_projects(issues),
         state <- record_unroutable_issues(state, issues) do
      if available_slots(state) > 0, do: choose_issues(issues, state), else: state
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp auto_assign_missing_projects(issues) when is_list(issues) do
    settings = Config.settings!()

    Enum.reduce(issues, [], fn issue, acc ->
      case Tracker.update_issue_project_from_repository(issue, settings) do
        {:ok, :updated} ->
          acc

        {:ok, :skipped} ->
          [issue | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp auto_assign_missing_projects(issues), do: issues

  defp maybe_sync_github_issue_intake(%State{} = state) do
    settings = Config.settings!()

    cond do
      not settings.github_intake.enabled ->
        state

      match?(%Task{}, state.github_intake_task) ->
        warn_if_github_issue_intake_task_overdue(state, settings)

      not github_issue_intake_due?(state, settings) ->
        state

      true ->
        task = start_github_issue_intake_task(settings, state.github_intake_attempts)

        %{
          state
          | github_intake_task: task,
            last_github_intake_sync_ms: System.monotonic_time(:millisecond)
        }
    end
  end

  defp start_github_issue_intake_task(settings, attempts) do
    Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
      run_github_issue_intake_sync(settings, attempts)
    end)
  end

  defp run_github_issue_intake_sync(settings, attempts) do
    module = github_issue_module()
    adapter = github_issue_intake_adapter()

    if module_exports?(module, :sync_open_issues_to_linear, 3) do
      case module.sync_open_issues_to_linear(settings, adapter, attempts) do
        {:ok, result, attempts} ->
          {{:ok, result}, attempts}

        result ->
          {result, attempts}
      end
    else
      Logger.debug("Skipping GitHub issue intake sync; #{inspect(module)} does not export sync_open_issues_to_linear/3")
      {{:skip, :missing_export}, attempts}
    end
  end

  defp warn_if_github_issue_intake_task_overdue(
         %State{last_github_intake_sync_ms: started_ms, github_intake_task: %Task{} = task} = state,
         settings
       )
       when is_integer(started_ms) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    if elapsed_ms >= settings.github_intake.interval_ms do
      Logger.warning(
        "GitHub issue intake sync task still running after #{elapsed_ms}ms " <>
          "interval_ms=#{settings.github_intake.interval_ms} pid=#{inspect(task.pid)}"
      )
    end

    state
  end

  defp warn_if_github_issue_intake_task_overdue(%State{} = state, _settings), do: state

  defp log_github_issue_intake_result({:ok, %{created: created, skipped: skipped, errors: errors}}) do
    Logger.info("GitHub issue intake sync completed created=#{created} skipped=#{skipped} errors=#{errors}")
  end

  defp log_github_issue_intake_result({:error, reason}) do
    Logger.warning("Skipping GitHub issue intake sync; failed: #{inspect(reason)}")
  end

  defp log_github_issue_intake_result({:skip, :missing_export}), do: :ok

  defp github_issue_intake_due?(%State{last_github_intake_sync_ms: nil}, _settings), do: true

  defp github_issue_intake_due?(%State{last_github_intake_sync_ms: last_sync_ms}, settings)
       when is_integer(last_sync_ms) do
    System.monotonic_time(:millisecond) - last_sync_ms >= settings.github_intake.interval_ms
  end

  defp maybe_sync_merged_linked_pull_requests_to_done(%State{} = state) do
    settings = Config.settings!()

    if done_sync_due?(state, settings) do
      state
      |> sync_merged_linked_pull_requests_to_done()
      |> Map.put(:last_done_sync_ms, System.monotonic_time(:millisecond))
    else
      state
    end
  end

  defp done_sync_due?(%State{last_done_sync_ms: nil}, _settings), do: true

  defp done_sync_due?(%State{last_done_sync_ms: last_sync_ms}, settings)
       when is_integer(last_sync_ms) do
    System.monotonic_time(:millisecond) - last_sync_ms >= settings.done_sync.interval_ms
  end

  defp maybe_plan_approved_landings(%State{} = state) do
    settings = Config.settings!()

    if landing_plan_due?(state, settings) do
      result = LandingPlanner.reconcile(settings, tracker_module(), github_pr_lookup_module())
      execution_result = landing_worker_module().execute(settings, tracker_module(), result.queue)

      if result.inspected > 0 or result.errors > 0 do
        Logger.info(
          "Approved to Land dry-run planning completed " <>
            "inspected=#{result.inspected} commented=#{result.commented} " <>
            "skipped=#{result.skipped} errors=#{result.errors}"
        )
      end

      if execution_result.enabled and (execution_result.attempted > 0 or execution_result.errors > 0) do
        Logger.info(
          "Approved to Land execution completed " <>
            "attempted=#{execution_result.attempted} merged=#{execution_result.merged} " <>
            "blocked=#{execution_result.blocked} repair_requested=#{execution_result.repair_requested} " <>
            "skipped=#{execution_result.skipped} errors=#{execution_result.errors}"
        )
      end

      %{state | last_landing_plan_ms: System.monotonic_time(:millisecond), landing_queue: result.queue}
    else
      state
    end
  end

  defp landing_plan_due?(_state, %{landing: %{enabled: false}}), do: false
  defp landing_plan_due?(%State{last_landing_plan_ms: nil}, %{landing: %{enabled: true}}), do: true

  defp landing_plan_due?(%State{last_landing_plan_ms: last_plan_ms}, settings)
       when is_integer(last_plan_ms) do
    settings.landing.enabled and
      System.monotonic_time(:millisecond) - last_plan_ms >= settings.landing.interval_ms
  end

  defp landing_plan_due?(_state, _settings), do: false

  defp review_rework_sync_due?(%State{last_review_rework_sync_ms: nil}, _settings), do: true

  defp review_rework_sync_due?(%State{last_review_rework_sync_ms: last_sync_ms}, settings)
       when is_integer(last_sync_ms) do
    System.monotonic_time(:millisecond) - last_sync_ms >= settings.review_rework.interval_ms
  end

  defp sync_merged_linked_pull_requests_to_done(%State{} = state) do
    states = post_merge_done_sync_states()
    module = tracker_module()

    if module_exports?(module, :fetch_issues_by_states, 1) do
      do_sync_merged_linked_pull_requests_to_done(state, module, states)
    else
      Logger.warning("Skipping merged linked PR Done sync; #{inspect(module)} does not export fetch_issues_by_states/1")
      state
    end
  end

  defp do_sync_merged_linked_pull_requests_to_done(%State{} = state, module, states) do
    case module.fetch_issues_by_states(states) do
      {:ok, issues} ->
        log_post_merge_done_sync_candidates(issues, states)

        issues
        |> Enum.reduce(state, &maybe_sync_merged_linked_pr_issue_to_done/2)
        |> sync_done_issue_source_github_issues(module)

      {:error, reason} ->
        Logger.warning("Skipping merged linked PR Done sync; failed to fetch Linear issues: #{inspect(reason)}")
        state

      other ->
        Logger.warning("Skipping merged linked PR Done sync; unexpected fetch result: #{inspect(other)}")
        state
    end
  end

  defp sync_done_issue_source_github_issues(%State{} = state, module) do
    states = done_sync_terminal_states()

    cond do
      states == [] ->
        state

      !module_exports?(module, :fetch_issues_by_states, 1) ->
        state

      true ->
        do_sync_done_issue_source_github_issues(state, module, states)
    end
  end

  defp do_sync_done_issue_source_github_issues(%State{} = state, module, states) do
    case module.fetch_issues_by_states(states) do
      {:ok, issues} when is_list(issues) ->
        log_done_issue_source_github_issue_candidates(issues, states)
        Enum.reduce(issues, state, &maybe_close_done_issue_source_github_issue/2)

      {:error, reason} ->
        Logger.warning("Skipping Linear Done source GitHub issue close sync; failed to fetch Linear issues: #{inspect(reason)}")

        state

      other ->
        Logger.warning("Skipping Linear Done source GitHub issue close sync; unexpected fetch result: #{inspect(other)}")

        state
    end
  end

  defp log_done_issue_source_github_issue_candidates(issues, states) when is_list(issues) do
    close_candidate_count =
      Enum.count(issues, fn issue ->
        match?(%Issue{}, issue) and issue_has_done_sync_evidence?(issue) and
          present_string?(RepositoryResolver.source_github_issue_url(issue))
      end)

    if close_candidate_count > 0 do
      Logger.info(
        "Merged PR Done sync inspecting #{close_candidate_count} already Done issue(s) " <>
          "with source GitHub issue evidence from #{length(issues)} fetched issue(s) " <>
          "states=#{inspect(states)}"
      )
    end
  end

  defp maybe_close_done_issue_source_github_issue(%Issue{} = issue, %State{} = state) do
    issue_url = RepositoryResolver.source_github_issue_url(issue)
    close_key = done_source_github_issue_close_key(issue, issue_url)

    cond do
      MapSet.member?(state.done_source_github_issue_closes, close_key) ->
        state

      !issue_has_done_sync_evidence?(issue) ->
        state

      !present_string?(issue_url) ->
        state

      true ->
        do_maybe_close_done_issue_source_github_issue(issue, issue_url, close_key, state)
    end
  end

  defp maybe_close_done_issue_source_github_issue(_issue, %State{} = state), do: state

  defp do_maybe_close_done_issue_source_github_issue(%Issue{} = issue, issue_url, close_key, %State{} = state) do
    attachment_urls = issue_attachment_urls(issue)

    case RepositoryResolver.resolve(issue, Config.settings!()) do
      {:ok, %{slug: repo}} when is_binary(repo) ->
        case done_source_github_issue_closed?(issue, repo, issue_url) do
          {:ok, true} ->
            Logger.info(
              "Merged PR Done sync skipping already closed source GitHub issue for #{issue_context(issue)} " <>
                "repo=#{repo} issue=#{issue_url}"
            )

            mark_done_source_github_issue_close(state, close_key)

          {:ok, false} ->
            close_done_issue_source_github_issue_with_merged_pr(issue, repo, attachment_urls, close_key, state)

          {:error, reason} ->
            Logger.warning(
              "Linear Done source GitHub issue close sync could not inspect source issue state for " <>
                "#{issue_context(issue)} repo=#{repo} issue=#{issue_url} reason=#{inspect(reason)}; " <>
                "continuing with merged PR lookup"
            )

            close_done_issue_source_github_issue_with_merged_pr(issue, repo, attachment_urls, close_key, state)
        end

      {:ok, other} ->
        Logger.warning(
          "Skipping Linear Done source GitHub issue close sync for #{issue_context(issue)}; " <>
            "repository resolver returned invalid result=#{inspect(other)}"
        )

        state

      {:error, reason} ->
        Logger.warning(
          "Skipping Linear Done source GitHub issue close sync for #{issue_context(issue)}; " <>
            "failed to resolve repository from issue metadata: #{inspect(reason)}"
        )

        state
    end
  end

  defp done_source_github_issue_closed?(%Issue{} = _issue, repo, issue_url) do
    module = github_issue_module()

    if module_exports?(module, :closed_at, 2) do
      case module.closed_at(repo, issue_url) do
        {:ok, closed_at} when is_binary(closed_at) ->
          {:ok, String.trim(closed_at) != ""}

        {:ok, _open_or_unknown} ->
          {:ok, false}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_closed_at_result, other}}
      end
    else
      {:ok, false}
    end
  end

  defp close_done_issue_source_github_issue_with_merged_pr(issue, repo, attachment_urls, close_key, state) do
    case lookup_merged_pull_request_for_done(issue, repo, attachment_urls) do
      {:ok, %{} = pr} ->
        Logger.info(
          "Merged PR Done sync closing source GitHub issue for already Done Linear issue: " <>
            "#{issue_context(issue)} repo=#{repo} pr=#{pr_url(pr)}"
        )

        case close_source_github_issue_after_done(issue, repo, pr) do
          {:ok, _status} ->
            mark_done_source_github_issue_close(state, close_key)

          _other ->
            state
        end

      {:ok, nil} ->
        state

      {:error, reason} ->
        Logger.warning(
          "Skipping Linear Done source GitHub issue close sync for #{issue_context(issue)}; " <>
            "repo=#{repo}; failed to inspect merged PR evidence: #{inspect(reason)}"
        )

        state

      other ->
        Logger.warning(
          "Skipping Linear Done source GitHub issue close sync for #{issue_context(issue)}; " <>
            "repo=#{repo}; unexpected PR lookup result=#{inspect(other)}"
        )

        state
    end
  end

  defp done_source_github_issue_close_key(%Issue{} = issue, issue_url) do
    {issue.id, issue_url}
  end

  defp mark_done_source_github_issue_close(%State{} = state, close_key) do
    %{state | done_source_github_issue_closes: MapSet.put(state.done_source_github_issue_closes, close_key)}
  end

  defp log_post_merge_done_sync_candidates(issues, states) when is_list(issues) do
    pull_request_issue_count = Enum.count(issues, &issue_has_done_sync_evidence?/1)

    if pull_request_issue_count > 0 do
      Logger.info(
        "Merged PR Done sync inspecting #{pull_request_issue_count} issue(s) with PR evidence " <>
          "from #{length(issues)} fetched issue(s) states=#{inspect(states)}"
      )
    end
  end

  defp post_merge_done_sync_states do
    Config.settings!().tracker.active_states
    |> Kernel.++([Config.review_handoff_state()])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp done_sync_terminal_states do
    [done_state_name()]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_sync_merged_linked_pr_issue_to_done(%Issue{} = issue, %State{} = state) do
    cond do
      done_sync_terminal_blocked?(state, issue.id) ->
        state

      done_sync_runtime_owned?(state, issue.id) ->
        clear_done_sync_attempt(state, issue.id)

      issue_has_done_sync_evidence?(issue) ->
        do_maybe_sync_merged_linked_pr_issue_to_done(issue, state)

      true ->
        state
    end
  end

  defp maybe_sync_merged_linked_pr_issue_to_done(_issue, %State{} = state), do: state

  defp do_maybe_sync_merged_linked_pr_issue_to_done(%Issue{} = issue, %State{} = state) do
    attachment_urls = issue_attachment_urls(issue)

    case RepositoryResolver.resolve(issue, Config.settings!()) do
      {:ok, %{slug: repo}} when is_binary(repo) ->
        maybe_move_merged_linked_pr_issue_to_done(issue, repo, attachment_urls, state)

      {:ok, other} ->
        record_done_sync_failure(
          state,
          issue,
          "repository resolver returned invalid result=#{inspect(other)}"
        )

      {:error, reason} ->
        record_done_sync_failure(
          state,
          issue,
          "failed to resolve repository from PR attachment metadata: #{inspect(reason)}"
        )
    end
  end

  defp maybe_move_merged_linked_pr_issue_to_done(issue, repo, attachment_urls, state) do
    case lookup_merged_pull_request_for_done(issue, repo, attachment_urls) do
      {:ok, %{} = pr} ->
        move_merged_linked_pr_issue_to_done(issue, repo, pr, state)

      {:ok, nil} ->
        clear_done_sync_attempt(state, issue.id)

      {:error, reason} ->
        record_done_sync_failure(
          state,
          issue,
          "repo=#{repo}; failed to inspect linked PR attachment: #{inspect(reason)}"
        )

      other ->
        record_done_sync_failure(
          state,
          issue,
          "repo=#{repo}; unexpected PR lookup result=#{inspect(other)}"
        )
    end
  end

  defp move_merged_linked_pr_issue_to_done(issue, repo, pr, state) do
    done_state = done_state_name()

    case tracker_module().update_issue_state(issue.id, done_state) do
      :ok ->
        Logger.info(
          "Merged linked PR detected; moved Linear issue to #{done_state}: " <>
            "#{issue_context(issue)} repo=#{repo} pr=#{pr_url(pr)}"
        )

        cleanup_landing_blocking_labels(issue)
        close_source_github_issue_after_done(issue, repo, pr)
        post_zero_touch_evidence_after_done(issue, repo, pr)

        state
        |> terminate_running_issue(issue.id, true)
        |> release_issue_claim(issue.id)
        |> complete_issue(issue.id)

      {:error, reason} ->
        record_done_sync_failure(
          state,
          issue,
          "merged PR detected but failed to move Linear issue to #{done_state}: " <>
            "repo=#{repo} pr=#{pr_url(pr)} reason=#{inspect(reason)}"
        )

      other ->
        record_done_sync_failure(
          state,
          issue,
          "merged PR detected but Linear state update returned unexpected result: " <>
            "repo=#{repo} pr=#{pr_url(pr)} result=#{inspect(other)}"
        )
    end
  end

  defp cleanup_landing_blocking_labels(%Issue{} = issue) do
    module = tracker_module()

    if function_exported?(module, :remove_issue_labels, 2) do
      case module.remove_issue_labels(issue.id, @landing_blocking_labels) do
        :ok ->
          :ok

        {:ok, _value} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to clean landing blocking labels for #{issue_context(issue)} after Done sync: #{inspect(reason)}")
          {:error, reason}

        other ->
          Logger.warning("Unexpected landing blocking label cleanup result for #{issue_context(issue)} after Done sync: #{inspect(other)}")
          {:error, {:linear_label_cleanup_unexpected, other}}
      end
    else
      Logger.debug("Skipping landing blocking label cleanup for #{issue_context(issue)}; tracker does not support label removal")
      :ok
    end
  end

  defp record_done_sync_failure(%State{} = state, %Issue{} = issue, reason) do
    policy = Config.retry_policy(:done_sync)
    previous_attempt = Map.get(state.retry_attempts, issue.id, %{})

    attempt_state =
      previous_attempt
      |> RetryPolicy.reset_on_progress(done_sync_evidence(issue))

    next_attempt = Map.get(attempt_state, :attempts, Map.get(attempt_state, :attempt, 0)) + 1
    error = "Skipping merged linked PR Done sync for #{issue_context(issue)}; #{reason}"

    if RetryPolicy.allow_attempt?(next_attempt, policy) do
      Logger.warning("#{error} attempt=#{next_attempt}")
      maybe_comment_on_done_sync_failure(issue, error, next_attempt)

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue.id, %{
              attempt: next_attempt,
              attempts: next_attempt,
              identifier: issue.identifier,
              error: error,
              policy_context: :done_sync,
              evidence_fingerprint: Map.get(attempt_state, :evidence_fingerprint),
              last_progress_at: Map.get(attempt_state, :last_progress_at)
            })
      }
    else
      terminal_error = RetryPolicy.terminal_reason(policy, next_attempt, error)

      Logger.warning(
        "Merged linked PR Done sync exhausted retries for #{issue_context(issue)} " <>
          "attempt=#{next_attempt}: #{terminal_error}"
      )

      state
      |> block_issue_from_entry(
        issue.id,
        %{
          identifier: issue.identifier,
          issue: issue,
          workspace_path: nil,
          worker_host: nil,
          session_id: nil,
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil
        },
        terminal_error
      )
      |> put_blocked_policy_terminal_context(issue.id, :done_sync)
    end
  end

  defp maybe_comment_on_done_sync_failure(%Issue{} = issue, error, 1) do
    module = tracker_module()

    if module_exports?(module, :create_comment, 2) do
      body = done_sync_failure_comment(issue, error)

      case module.create_comment(issue.id, body) do
        :ok ->
          :ok

        {:ok, _comment} ->
          :ok

        {:error, reason} ->
          Logger.warning("Merged linked PR Done sync could not leave failure comment for #{issue_context(issue)}: #{inspect(reason)}")

        other ->
          Logger.warning("Merged linked PR Done sync failure comment returned unexpected result for #{issue_context(issue)}: #{inspect(other)}")
      end
    end
  rescue
    exception ->
      Logger.warning("Merged linked PR Done sync failure comment crashed for #{issue_context(issue)}: #{Exception.message(exception)}")
  end

  defp maybe_comment_on_done_sync_failure(_issue, _error, _attempt), do: :ok

  defp done_sync_failure_comment(%Issue{} = issue, error) do
    """
    Symphony warning: merged PR Done sync could not complete for #{issue.identifier || issue.id}.

    #{error}
    """
    |> String.trim()
  end

  defp clear_done_sync_attempt(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{policy_context: :done_sync} ->
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      _other ->
        state
    end
  end

  defp done_sync_terminal_blocked?(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id)
    |> policy_terminal_context?(:done_sync)
  end

  defp done_sync_runtime_owned?(%State{} = state, issue_id) do
    Map.has_key?(state.running, issue_id) or pending_review_handoff_for_issue?(state, issue_id)
  end

  defp put_blocked_policy_terminal_context(%State{} = state, issue_id, context) do
    blocked =
      Map.update(state.blocked, issue_id, %{policy_terminal_context: context}, fn entry ->
        Map.put(entry, :policy_terminal_context, context)
      end)

    %{state | blocked: blocked}
  end

  defp issue_has_pull_request_attachment?(%Issue{} = issue) do
    issue
    |> issue_attachment_urls()
    |> Enum.any?(&github_pull_request_url?/1)
  end

  defp issue_has_done_sync_evidence?(%Issue{} = issue) do
    issue_has_pull_request_attachment?(issue) or
      present_string?(issue.branch_name) or
      (RepositoryResolver.repository_hint?(issue) and
         (present_string?(issue.identifier) or present_string?(issue.url)))
  end

  defp handoff_pr_evidence(running_entry) when is_map(running_entry) do
    issue = Map.get(running_entry, :issue)

    %{
      branch_name: Map.get(running_entry, :branch_name) || issue_branch_name(issue),
      attachment_urls: issue_attachment_urls(issue)
    }
  end

  defp handoff_pr_evidence(_running_entry), do: %{}

  defp blocked_review_handoff_evidence(entry) when is_map(entry) do
    handoff_pr_evidence(entry)
  end

  defp done_sync_evidence(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      url: issue.url,
      branch_name: issue.branch_name,
      attachment_urls: issue_attachment_urls(issue)
    }
  end

  defp issue_branch_name(%Issue{branch_name: branch_name}), do: branch_name
  defp issue_branch_name(_issue), do: nil

  defp github_pull_request_url?(url) when is_binary(url) do
    Regex.match?(~r{^https://github\.com/[^/]+/[^/]+/pull/\d+(?:[/?#].*)?$}i, String.trim(url))
  end

  defp github_pull_request_url?(_url), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp lookup_merged_pull_request_for_done(%Issue{} = issue, repo, attachment_urls) do
    if present_string?(issue.branch_name) do
      lookup_implementation_merged_pull_request_for_done(issue, repo, attachment_urls)
    else
      lookup_merged_linked_pull_request_for_done(issue, repo, attachment_urls, true)
    end
  end

  defp lookup_implementation_merged_pull_request_for_done(%Issue{} = issue, repo, attachment_urls) do
    case lookup_merged_issue_pull_request(repo, issue) do
      {:ok, %{} = pr} ->
        Logger.info(
          "Merged PR Done sync selected implementation PR for #{issue_context(issue)} " <>
            "repo=#{repo} branch=#{issue.branch_name} pr=#{pr_url(pr)} source=#{inspect(pr_lookup_source(pr))}"
        )

        {:ok, pr}

      {:ok, nil} ->
        lookup_open_or_linked_pull_request_for_done(issue, repo, attachment_urls)

      {:error, reason} ->
        Logger.warning(
          "Merged PR Done sync rejected implementation lookup for #{issue_context(issue)} " <>
            "repo=#{repo} branch=#{issue.branch_name} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp lookup_open_or_linked_pull_request_for_done(%Issue{} = issue, repo, attachment_urls) do
    case lookup_open_issue_pull_request_for_done(repo, issue, attachment_urls) do
      {:ok, %{} = pr} ->
        Logger.info(
          "Merged PR Done sync rejected linked PR attachments for #{issue_context(issue)} " <>
            "repo=#{repo} branch=#{issue.branch_name}; implementation PR is still open pr=#{pr_url(pr)}"
        )

        {:ok, nil}

      {:ok, nil} ->
        Logger.info(
          "Merged PR Done sync found no merged or open implementation PR for #{issue_context(issue)} " <>
            "repo=#{repo} branch=#{issue.branch_name}; checking linked PR attachments for branch match"
        )

        lookup_branch_matched_merged_linked_pull_request_for_done(issue, repo, attachment_urls)

      {:error, reason} ->
        Logger.warning(
          "Merged PR Done sync rejected linked PR attachments for #{issue_context(issue)} " <>
            "repo=#{repo} branch=#{issue.branch_name}; implementation PR lookup failed reason=#{inspect(reason)}"
        )

        {:error, {:implementation_pr_lookup_failed, reason}}
    end
  end

  defp lookup_branch_matched_merged_linked_pull_request_for_done(%Issue{} = issue, repo, attachment_urls) do
    case lookup_merged_linked_pull_request_for_done(issue, repo, attachment_urls, false) do
      {:ok, %{} = pr} ->
        if pr_branch_matches_issue?(pr, issue) do
          Logger.info(
            "Merged PR Done sync accepted linked PR attachment for #{issue_context(issue)} " <>
              "repo=#{repo} branch=#{issue.branch_name} pr=#{pr_url(pr)} head=#{inspect(pr_head_ref(pr))}"
          )

          {:ok, pr}
        else
          Logger.info(
            "Merged PR Done sync rejected linked PR attachment for #{issue_context(issue)} " <>
              "repo=#{repo} branch=#{issue.branch_name} pr=#{pr_url(pr)} head=#{inspect(pr_head_ref(pr))} " <>
              "reason=:branch_mismatch_after_implementation_lookup"
          )

          {:ok, nil}
        end

      other ->
        other
    end
  end

  defp lookup_merged_linked_pull_request_for_done(%Issue{} = issue, repo, attachment_urls, fallback_to_issue_evidence?) do
    if Enum.any?(attachment_urls, &github_pull_request_url?/1) do
      lookup_merged_linked_pull_request(repo, attachment_urls)
      |> handle_merged_linked_pull_request_for_done(issue, repo, fallback_to_issue_evidence?)
    else
      fallback_to_merged_issue_pull_request_for_done(issue, repo, fallback_to_issue_evidence?)
    end
  end

  defp handle_merged_linked_pull_request_for_done({:ok, %{} = pr}, issue, repo, fallback_to_issue_evidence?) do
    if linked_done_sync_pr_matches_issue?(issue, pr, fallback_to_issue_evidence?) do
      Logger.info(
        "Merged PR Done sync selected linked PR attachment for #{issue_context(issue)} " <>
          "repo=#{repo} pr=#{pr_url(pr)} source=#{inspect(pr_lookup_source(pr))}"
      )

      {:ok, pr}
    else
      Logger.info(
        "Merged PR Done sync rejected linked PR attachment for #{issue_context(issue)} " <>
          "repo=#{repo} pr=#{pr_url(pr)} linked_branch=#{inspect(pr_head_branch(pr))} " <>
          "implementation_branch=#{inspect(issue.branch_name)}"
      )

      {:ok, nil}
    end
  end

  defp handle_merged_linked_pull_request_for_done({:ok, nil}, issue, repo, fallback_to_issue_evidence?) do
    Logger.info(
      "Merged PR Done sync rejected linked PR attachments for #{issue_context(issue)} " <>
        "repo=#{repo}; no merged linked PR found"
    )

    fallback_to_merged_issue_pull_request_for_done(issue, repo, fallback_to_issue_evidence?)
  end

  defp handle_merged_linked_pull_request_for_done(
         {:error, {:missing_lookup_merged_linked_pull_request, _module}},
         issue,
         repo,
         fallback_to_issue_evidence?
       ) do
    fallback_to_merged_issue_pull_request_for_done(issue, repo, fallback_to_issue_evidence?)
  end

  defp handle_merged_linked_pull_request_for_done(
         {:error, {:ambiguous_linked_pull_requests, _urls} = reason},
         issue,
         repo,
         fallback_to_issue_evidence?
       ) do
    Logger.info(
      "Merged PR Done sync ignored ambiguous linked PR attachments for #{issue_context(issue)} " <>
        "repo=#{repo} reason=#{inspect(reason)}; falling back to issue evidence"
    )

    fallback_to_merged_issue_pull_request_for_done(issue, repo, fallback_to_issue_evidence?)
  end

  defp handle_merged_linked_pull_request_for_done({:error, reason}, issue, repo, _fallback_to_issue_evidence?) do
    Logger.warning(
      "Merged PR Done sync rejected linked PR attachments for #{issue_context(issue)} " <>
        "repo=#{repo} reason=#{inspect(reason)}"
    )

    {:error, reason}
  end

  defp handle_merged_linked_pull_request_for_done(other, _issue, _repo, _fallback_to_issue_evidence?), do: other

  defp fallback_to_merged_issue_pull_request_for_done(issue, repo, true),
    do: lookup_merged_issue_pull_request(repo, issue)

  defp fallback_to_merged_issue_pull_request_for_done(_issue, _repo, false), do: {:ok, nil}

  defp linked_done_sync_pr_matches_issue?(_issue, _pr, true), do: true

  defp linked_done_sync_pr_matches_issue?(%Issue{branch_name: branch_name}, pr, false) do
    present_string?(branch_name) and pr_head_branch(pr) == branch_name
  end

  defp pr_head_branch(%{"headRefName" => branch}) when is_binary(branch), do: branch
  defp pr_head_branch(%{headRefName: branch}) when is_binary(branch), do: branch
  defp pr_head_branch(_pr), do: nil

  defp pr_lookup_source(%{"__symphonyLookupSource" => source}), do: source
  defp pr_lookup_source(_pr), do: nil

  defp pr_branch_matches_issue?(%{} = pr, %Issue{branch_name: branch_name}) when is_binary(branch_name) do
    String.trim(branch_name) != "" and pr_head_ref(pr) == String.trim(branch_name)
  end

  defp pr_branch_matches_issue?(_pr, _issue), do: false

  defp pr_head_ref(%{"headRefName" => branch}) when is_binary(branch), do: String.trim(branch)
  defp pr_head_ref(%{headRefName: branch}) when is_binary(branch), do: String.trim(branch)
  defp pr_head_ref(_pr), do: nil

  defp close_source_github_issue_after_done(%Issue{} = issue, repo, pr) do
    issue_url = RepositoryResolver.source_github_issue_url(issue)
    module = github_issue_module()
    comment = source_github_issue_close_comment(issue, pr)

    if module_exports?(module, :close_if_open, 3) do
      case module.close_if_open(repo, issue_url, comment) do
        {:ok, :closed} ->
          Logger.info("Closed source GitHub issue for #{issue_context(issue)} repo=#{repo} issue=#{issue_url}")
          {:ok, :closed}

        {:ok, _status} = result ->
          result

        {:error, reason} = error ->
          Logger.warning(
            "Merged PR Done sync could not close source GitHub issue for #{issue_context(issue)} " <>
              "repo=#{repo} issue=#{inspect(issue_url)} reason=#{inspect(reason)}"
          )

          error
      end
    else
      Logger.warning(
        "Skipping source GitHub issue close for #{issue_context(issue)}; " <>
          "#{inspect(module)} does not export close_if_open/3"
      )

      {:error, {:missing_close_if_open, module}}
    end
  end

  defp post_zero_touch_evidence_after_done(%Issue{} = issue, repo, pr) do
    module = zero_touch_evidence_module()

    if module_exports?(module, :maybe_post_after_done, 5) do
      case module.maybe_post_after_done(issue, repo, pr, tracker_module(), github_issue_module()) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Zero-touch loop evidence comment skipped for #{issue_context(issue)}: #{inspect(reason)}")

        other ->
          Logger.warning("Zero-touch loop evidence comment returned unexpected result for #{issue_context(issue)}: #{inspect(other)}")
      end
    end
  end

  defp source_github_issue_close_comment(%Issue{} = issue, pr) do
    """
    Closed by Symphony after merged PR #{pr_url(pr)} moved #{issue.identifier || issue.id} to Done in Linear.
    """
    |> String.trim()
  end

  defp lookup_merged_linked_pull_request(repo, attachment_urls) do
    lookup_module = github_pr_lookup_module()

    if module_exports?(lookup_module, :lookup_merged_linked_pull_request, 2) do
      lookup_module.lookup_merged_linked_pull_request(repo, attachment_urls)
    else
      {:error, {:missing_lookup_merged_linked_pull_request, lookup_module}}
    end
  end

  defp lookup_merged_issue_pull_request(repo, %Issue{} = issue) do
    lookup_module = github_pr_lookup_module()

    if module_exports?(lookup_module, :lookup_merged_issue_pull_request, 4) do
      lookup_module.lookup_merged_issue_pull_request(repo, issue.identifier, issue.url, issue.branch_name)
    else
      {:ok, nil}
    end
  end

  defp lookup_open_issue_pull_request_for_done(repo, %Issue{} = issue, _attachment_urls) do
    lookup_module = github_pr_lookup_module()

    if module_exports?(lookup_module, :lookup_open_issue_pull_request, 5) do
      # Done sync uses open lookup only to detect an active implementation PR.
      # Linked attachments are handled separately by the merged-linked branch gate.
      lookup_module.lookup_open_issue_pull_request(
        repo,
        issue.identifier,
        issue.url,
        issue.branch_name,
        []
      )
    else
      {:ok, nil}
    end
  end

  defp done_state_name do
    Config.settings!().tracker.terminal_states
    |> Enum.find("Done", fn state -> normalize_issue_state(to_string(state)) == "done" end)
  end

  defp reconcile_active_open_pr_handoffs(%State{} = state) do
    states = active_open_pr_handoff_reconcile_states()
    module = tracker_module()

    cond do
      states == [] ->
        state

      !module_exports?(module, :fetch_issues_by_states, 1) ->
        state

      !open_issue_pr_lookup_available?() ->
        state

      true ->
        do_reconcile_active_open_pr_handoffs(state, module, states)
    end
  end

  defp do_reconcile_active_open_pr_handoffs(%State{} = state, module, states) do
    case module.fetch_issues_by_states(states) do
      {:ok, issues} when is_list(issues) ->
        Enum.reduce(issues, state, &maybe_reconcile_active_open_pr_handoff/2)

      {:error, reason} ->
        Logger.debug("Failed to fetch active issues for open PR handoff reconcile: #{inspect(reason)}")
        state

      other ->
        Logger.debug("Unexpected active issue fetch result for open PR handoff reconcile: #{inspect(other)}")
        state
    end
  end

  defp active_open_pr_handoff_reconcile_states do
    Config.settings!().tracker.active_states
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(normalize_issue_state(&1) == "in progress"))
    |> Enum.uniq()
  end

  defp reconcile_review_rework_requests(%State{} = state) do
    settings = Config.settings!()
    states = review_rework_states(settings)
    module = tracker_module()

    cond do
      not settings.review_rework.enabled ->
        state

      states == [] ->
        state

      !module_exports?(module, :fetch_issues_by_states, 1) ->
        state

      not review_rework_sync_due?(state, settings) ->
        state

      true ->
        state
        |> do_reconcile_review_rework_requests(module, states, settings.review_rework)
        |> Map.put(:last_review_rework_sync_ms, System.monotonic_time(:millisecond))
    end
  end

  defp do_reconcile_review_rework_requests(%State{} = state, module, states, review_rework) do
    case module.fetch_issues_by_states(states) do
      {:ok, issues} when is_list(issues) ->
        Enum.reduce(issues, state, &maybe_reconcile_review_rework_request(&1, &2, review_rework))

      {:error, reason} ->
        Logger.debug("Failed to fetch In Review issues for review rework reconcile: #{inspect(reason)}")
        state

      other ->
        Logger.debug("Unexpected In Review issue fetch result for review rework reconcile: #{inspect(other)}")
        state
    end
  end

  defp review_rework_states(settings) do
    [settings.review.handoff_state, settings.tracker.review_state]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "nil"))
    |> Enum.uniq()
  end

  defp maybe_reconcile_review_rework_request(%Issue{} = issue, %State{} = state, review_rework) do
    if review_rework_candidate?(issue, state) do
      reconcile_review_rework_request(issue, state, review_rework)
    else
      state
    end
  end

  defp maybe_reconcile_review_rework_request(_issue, %State{} = state, _review_rework), do: state

  defp review_rework_candidate?(%Issue{id: issue_id} = issue, %State{} = state) when is_binary(issue_id) do
    !Map.has_key?(state.running, issue_id) and
      !Map.has_key?(state.blocked, issue_id) and
      !pending_review_handoff_for_issue?(state, issue_id) and
      is_binary(review_rework_pr_url(issue))
  end

  defp review_rework_candidate?(_issue, _state), do: false

  defp reconcile_review_rework_request(%Issue{} = issue, %State{} = state, review_rework) do
    pr_url = review_rework_pr_url(issue)
    review_status_module = github_review_status_module()

    case review_status_module.view(pr_url) do
      {:ok, status} ->
        maybe_start_review_rework(issue, state, review_rework, pr_url, status)

      {:error, reason} ->
        Logger.debug("Failed to inspect PR review state for #{issue_context(issue)} pr=#{pr_url}: #{inspect(reason)}")
        state
    end
  end

  defp maybe_start_review_rework(%Issue{} = issue, %State{} = state, review_rework, pr_url, status) do
    cond do
      not GitHubReviewStatus.open?(status) ->
        state

      GitHubReviewStatus.changes_requested?(status) ->
        start_review_rework(issue, state, review_rework, pr_url, status)

      true ->
        state
    end
  end

  defp start_review_rework(%Issue{} = issue, %State{} = state, review_rework, pr_url, status) do
    review_id = review_rework_review_id(status, pr_url)
    round_state = Map.get(state.review_rework_rounds, issue.id, %{rounds: 0})

    cond do
      Map.get(round_state, :last_review_id) == review_id ->
        state

      Map.get(round_state, :rounds, 0) >= review_rework.max_rounds ->
        block_issue_before_dispatch(
          state,
          issue,
          "review rework round limit reached (#{review_rework.max_rounds}) for pr=#{pr_url} review=#{review_id}"
        )

      true ->
        do_start_review_rework(issue, state, pr_url, status, review_id, round_state)
    end
  end

  defp do_start_review_rework(%Issue{} = issue, %State{} = state, pr_url, status, review_id, round_state) do
    target_state = review_handoff_block_state()
    next_round = Map.get(round_state, :rounds, 0) + 1

    case Tracker.update_issue_state(issue.id, target_state) do
      :ok ->
        Tracker.create_comment(issue.id, review_rework_comment(issue, pr_url, status, review_id, next_round))

        Logger.info(
          "Dispatching review rework for #{issue_context(issue)} pr=#{pr_url} " <>
            "review=#{review_id} round=#{next_round}"
        )

        state =
          %{
            state
            | review_rework_rounds:
                Map.put(state.review_rework_rounds, issue.id, %{
                  rounds: next_round,
                  last_review_id: review_id,
                  pr_url: pr_url
                })
          }

        rework_issue = %{issue | state: target_state}

        rework_opts = [
          extra_prompt: review_rework_prompt(issue, pr_url, status, next_round),
          allow_dirty_existing_workspace: true
        ]

        do_dispatch_issue(state, rework_issue, nil, nil, rework_opts)

      {:error, reason} ->
        Logger.warning(
          "Failed to move review rework issue back to #{target_state}: #{issue_context(issue)} " <>
            "pr=#{pr_url} review=#{review_id} reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp review_rework_pr_url(%Issue{} = issue) do
    issue
    |> issue_attachment_urls()
    |> Enum.find(&github_pull_request_url?/1)
  end

  defp review_rework_review_id(status, pr_url) when is_map(status) do
    Map.get(status, :latest_changes_requested_review_id) ||
      Map.get(status, "latest_changes_requested_review_id") ||
      "#{pr_url}:changes_requested"
  end

  defp review_rework_comment(%Issue{} = issue, pr_url, status, review_id, round) do
    """
    Symphony detected GitHub changes requested for #{issue.identifier}.

    PR: #{pr_url}
    Review: #{review_id}
    Rework round: #{round}

    The runtime moved this issue back to #{review_handoff_block_state()} and dispatched a rework agent with the review feedback.
    Review feedback:
    #{blank_to_none(review_rework_feedback(status))}
    """
    |> String.trim()
  end

  defp review_rework_prompt(%Issue{} = issue, pr_url, status, round) do
    """
    GitHub review rework request:

    The human reviewer requested changes on the existing PR.

    Linear issue:
    - Identifier: #{issue.identifier}
    - Title: #{issue.title || "Automated changes"}

    PR: #{pr_url}
    Rework round: #{round}

    Review feedback:
    #{blank_to_none(review_rework_feedback(status))}

    Rules:
    - Address the requested changes in the existing workspace and branch.
    - Push branch updates to the existing PR.
    - Do not merge.
    - Do not approve on GitHub.
    """
    |> String.trim()
  end

  defp review_rework_feedback(status) when is_map(status) do
    Map.get(status, :changes_requested_body) || Map.get(status, "changes_requested_body") || ""
  end

  defp maybe_reconcile_active_open_pr_handoff(%Issue{} = issue, %State{} = state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    if open_pr_handoff_reconcile_candidate?(issue, state, active_states, terminal_states) do
      reconcile_active_open_pr_handoff(issue, state)
    else
      state
    end
  end

  defp maybe_reconcile_active_open_pr_handoff(_issue, %State{} = state), do: state

  defp open_pr_handoff_reconcile_candidate?(
         %Issue{id: issue_id, state: state_name} = issue,
         %State{} = state,
         active_states,
         terminal_states
       )
       when is_binary(issue_id) do
    normalize_issue_state(state_name) == "in progress" and
      candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(state.completed, issue_id) and
      open_pr_handoff_claim_reconcilable?(state, issue_id) and
      !Map.has_key?(state.blocked, issue_id) and
      !pending_review_handoff_for_issue?(state, issue_id)
  end

  defp open_pr_handoff_reconcile_candidate?(_issue, _state, _active_states, _terminal_states),
    do: false

  defp open_pr_handoff_claim_reconcilable?(%State{} = state, issue_id) do
    !MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id)
  end

  defp reconcile_active_open_pr_handoff(%Issue{} = issue, %State{} = state) do
    case lookup_open_pr_for_dispatch(issue) do
      {:ok, %{} = pr} ->
        {:handoff, state} = start_reconciled_open_pr_handoff(state, issue, pr)
        state

      {:ok, nil} ->
        state

      {:error, {:ambiguous_open_issue_pull_requests, _urls} = reason} ->
        error = "ambiguous open GitHub PRs found during active issue reconcile: #{inspect(reason)}"
        Logger.warning("Blocking active issue reconcile for #{issue_context(issue)}: #{error}")
        block_issue_before_dispatch(state, issue, error)

      {:error, reason} ->
        Logger.warning("Continuing active issue reconcile for #{issue_context(issue)}; open PR guard lookup failed: #{inspect(reason)}")

        state
    end
  end

  defp start_reconciled_open_pr_handoff(%State{} = state, %Issue{} = issue, %{} = pr) do
    case Map.get(state.running, issue.id) do
      nil ->
        start_existing_open_pr_handoff(state, issue, pr, reason: :polling_reconcile)

      running_entry ->
        start_running_open_pr_handoff(state, issue, running_entry, pr)
    end
  end

  defp start_running_open_pr_handoff(%State{} = state, %Issue{} = issue, running_entry, %{} = pr) do
    session_id = open_pr_handoff_session_id(:polling_reconcile)

    running_entry =
      running_entry
      |> refresh_running_entry_issue(issue)
      |> Map.put(:branch_name, pr["headRefName"] || Map.get(running_entry, :branch_name) || issue.branch_name)
      |> Map.put(:session_id, Map.get(running_entry, :session_id) || session_id)

    Logger.info(
      "Open PR discovered during active running issue reconcile for #{issue_context(issue)}; " <>
        "stopping implementation worker and starting review handoff pr=#{pr_url(pr)}"
    )

    state =
      state
      |> terminate_running_issue(issue.id, false)
      |> Map.update!(:claimed, &MapSet.put(&1, issue.id))

    {:handoff, start_review_handoff_task(state, :normal, issue.id, running_entry, session_id, pr, nil)}
  end

  defp reconcile_running_issues(%State{} = state) do
    state =
      state
      |> reconcile_stalled_running_issues()
      |> reconcile_stalled_review_handoffs()

    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_blocked_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec unroutable_issue_entries_for_test([Issue.t()], State.t()) :: [map()]
  def unroutable_issue_entries_for_test(issues, %State{} = state) when is_list(issues) do
    state
    |> record_unroutable_issues(issues)
    |> Map.fetch!(:unroutable)
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec claim_issue_for_dispatch_for_test(Issue.t(), (String.t(), String.t() -> term())) ::
          {:ok, Issue.t()} | {:error, term()}
  def claim_issue_for_dispatch_for_test(%Issue{} = issue, state_updater)
      when is_function(state_updater, 2) do
    claim_issue_for_dispatch(issue, state_updater)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec auto_assign_missing_projects_for_test([Issue.t()]) :: [Issue.t()]
  def auto_assign_missing_projects_for_test(issues) when is_list(issues) do
    auto_assign_missing_projects(issues)
  end

  @doc false
  @spec sync_github_issue_intake_for_test(State.t()) :: State.t()
  def sync_github_issue_intake_for_test(%State{} = state) do
    maybe_sync_github_issue_intake(state)
  end

  @doc false
  @spec sync_merged_linked_pull_requests_to_done_for_test(State.t()) :: State.t()
  def sync_merged_linked_pull_requests_to_done_for_test(%State{} = state) do
    maybe_sync_merged_linked_pull_requests_to_done(state)
  end

  @doc false
  @spec plan_approved_landings_for_test(State.t()) :: State.t()
  def plan_approved_landings_for_test(%State{} = state) do
    maybe_plan_approved_landings(state)
  end

  @doc false
  @spec reconcile_review_rework_requests_for_test(State.t()) :: State.t()
  def reconcile_review_rework_requests_for_test(%State{} = state) do
    reconcile_review_rework_requests(state)
  end

  @doc false
  @spec running_entry_for_test(Issue.t(), keyword()) :: map()
  def running_entry_for_test(%Issue{} = issue, opts \\ []) do
    new_running_entry(
      issue,
      Keyword.get(opts, :pid),
      Keyword.get(opts, :ref),
      Keyword.get(opts, :worker_host),
      Keyword.get(opts, :attempt),
      Keyword.get(opts, :agent_opts, [])
    )
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  if Mix.env() == :test do
    @doc false
    @spec preserve_orchestrator_state_for_test(State.t(), String.t(), (State.t() -> State.t())) :: State.t()
    def preserve_orchestrator_state_for_test(%State{} = state, operation, fun) when is_function(fun, 1) do
      preserve_orchestrator_state(state, operation, fun)
    end
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      review_issue_state?(issue.state) ->
        reconcile_review_handoff_issue_state(issue, state)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp review_issue_state?(state) when is_binary(state) do
    String.trim(state) == Config.settings!().tracker.review_state
  end

  defp review_issue_state?(_state), do: false

  defp reconcile_review_handoff_issue_state(%Issue{} = issue, %State{} = state) do
    refreshed_issue = refresh_review_handoff_issue(issue)

    if review_issue_state?(refreshed_issue.state) do
      do_reconcile_review_handoff_issue_state(refreshed_issue, state)
    else
      Logger.info("Issue left review state before handoff guard after refresh: #{issue_context(refreshed_issue)} state=#{refreshed_issue.state}")
      refresh_running_issue_state(state, refreshed_issue)
    end
  end

  defp do_reconcile_review_handoff_issue_state(%Issue{} = issue, %State{} = state) do
    case Map.get(state.running, issue.id) do
      nil ->
        state

      running_entry ->
        running_entry = refresh_running_entry_issue(running_entry, issue)

        case branch_name_and_workspace(running_entry) do
          {:ok, branch_name, workspace_path} ->
            reconcile_review_handoff_with_pr_lookup(
              issue,
              state,
              running_entry,
              branch_name,
              workspace_path
            )

          :missing ->
            error = "issue moved to #{issue.state} without branch metadata for GitHub PR lookup"
            Logger.warning("Agent task blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{running_entry_session_id(running_entry)}: #{error}")
            stop_and_block_review_handoff_issue(state, issue, running_entry, error)
        end
    end
  end

  defp refresh_review_handoff_issue(%Issue{} = issue) do
    module = tracker_module()

    if module_exports?(module, :fetch_issue_states_by_ids, 1) do
      case module.fetch_issue_states_by_ids([issue.id]) do
        {:ok, [%Issue{} = refreshed_issue | _rest]} ->
          refreshed_issue

        {:ok, []} ->
          Logger.warning("Could not refresh review handoff issue before PR lookup: issue_id=#{issue.id} reason=:not_found")
          issue

        {:error, reason} ->
          Logger.warning("Could not refresh review handoff issue before PR lookup: issue_id=#{issue.id} reason=#{inspect(reason)}")
          issue

        other ->
          Logger.warning("Could not refresh review handoff issue before PR lookup: issue_id=#{issue.id} result=#{inspect(other)}")
          issue
      end
    else
      issue
    end
  end

  defp refresh_running_entry_issue(running_entry, %Issue{} = issue) when is_map(running_entry) do
    Map.update(running_entry, :issue, issue, fn
      %Issue{} = running_issue -> merge_refreshed_issue(running_issue, issue)
      _other -> issue
    end)
  end

  defp refresh_running_entry_issue(running_entry, _issue), do: running_entry

  defp merge_refreshed_issue(%Issue{} = running_issue, %Issue{} = refreshed_issue) do
    %{
      refreshed_issue
      | branch_name: first_present(refreshed_issue.branch_name, running_issue.branch_name),
        labels: first_present(refreshed_issue.labels, running_issue.labels),
        blocked_by: first_present(refreshed_issue.blocked_by, running_issue.blocked_by)
    }
  end

  defp first_present(value, fallback) when value in [nil, ""], do: fallback
  defp first_present([], fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp reconcile_review_handoff_with_pr_lookup(
         %Issue{} = issue,
         %State{} = state,
         running_entry,
         branch_name,
         workspace_path
       ) do
    session_id = running_entry_session_id(running_entry)

    case lookup_pr_for_handoff(workspace_path, running_entry, branch_name) do
      {:ok, pr} when is_map(pr) ->
        Logger.info("Issue moved to review state after PR discovery: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        review_premature_handoff_pr(state, issue, running_entry, session_id, pr)

      {:ok, nil} ->
        error =
          "issue moved to #{issue.state} without discoverable GitHub PR for branch #{branch_name} or linked PR attachments; agent-owned PR is required before handoff"

        Logger.warning("Agent task blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")
        stop_and_block_review_handoff_issue(state, issue, running_entry, error)

      {:error, reason} ->
        error = "issue moved to #{issue.state} but GitHub PR lookup failed for branch #{branch_name}: #{inspect(reason)}"

        Logger.warning("Agent task blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")
        stop_and_block_review_handoff_issue(state, issue, running_entry, error)

      _other ->
        error = "issue moved to #{issue.state} but GitHub PR lookup returned unexpected result for branch #{branch_name}"

        Logger.warning("Agent task blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")
        stop_and_block_review_handoff_issue(state, issue, running_entry, error)
    end
  end

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue.identifier, blocked_issue_worker_host(state, issue.id))
        release_issue_claim(state, issue.id)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        reconcile_active_blocked_issue_state(state, issue)

      review_issue_state?(issue.state) ->
        reconcile_review_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_active_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case maybe_recover_done_sync_blocked_open_pr_handoff(state, issue) do
      {:ok, recovered_state} ->
        recovered_state

      :miss ->
        maybe_recover_active_review_handoff_issue(state, issue)
    end
  end

  defp maybe_recover_active_review_handoff_issue(%State{} = state, %Issue{} = issue) do
    case maybe_recover_blocked_review_handoff_issue(state, issue) do
      {:ok, recovered_state} -> recovered_state
      :miss -> refresh_blocked_issue_state(state, issue)
    end
  end

  defp maybe_recover_done_sync_blocked_open_pr_handoff(%State{} = state, %Issue{} = issue) do
    with blocked_entry when is_map(blocked_entry) <- Map.get(state.blocked, issue.id),
         true <- policy_terminal_context?(blocked_entry, :done_sync),
         false <- pending_review_handoff_for_issue?(state, issue.id),
         true <- open_issue_pr_lookup_available?() do
      case lookup_open_pr_for_dispatch(issue) do
        {:ok, %{} = pr} ->
          Logger.info(
            "Recovering Done sync blocked issue after open PR discovery: " <>
              "#{issue_context(issue)} pr=#{pr_url(pr)}"
          )

          state = release_issue_claim(state, issue.id)

          {:handoff, recovered_state} =
            start_existing_open_pr_handoff(state, issue, pr,
              reason: :blocked_done_sync_reconcile,
              release_claim_on_completion: true
            )

          {:ok, recovered_state}

        {:ok, nil} ->
          :miss

        {:error, reason} ->
          Logger.warning(
            "Continuing Done sync blocked issue reconcile for #{issue_context(issue)}; " <>
              "open PR lookup failed: #{inspect(reason)}"
          )

          :miss

        other ->
          Logger.warning(
            "Continuing Done sync blocked issue reconcile for #{issue_context(issue)}; " <>
              "open PR lookup returned unexpected result: #{inspect(other)}"
          )

          :miss
      end
    else
      _other -> :miss
    end
  end

  defp reconcile_review_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case guard_blocked_review_handoff_issue(state, issue) do
      {:ok, guarded_state} ->
        guarded_state

      :miss ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp maybe_recover_blocked_review_handoff_issue(%State{} = state, %Issue{} = issue) do
    with %{error: error} = blocked_entry <- Map.get(state.blocked, issue.id),
         false <- pending_review_handoff_for_issue?(state, issue.id),
         true <- review_handoff_pr_missing_error?(error),
         false <- policy_terminal_context?(blocked_entry, :blocked_review_handoff),
         recovered_entry <- refresh_blocked_review_handoff_entry(blocked_entry, issue),
         {:ok, branch_name, workspace_path} <- branch_name_and_workspace(recovered_entry),
         {:ok, attempt, attempt_state} <-
           begin_policy_attempt(
             blocked_entry,
             :blocked_review_handoff,
             blocked_review_handoff_evidence(recovered_entry)
           ) do
      case lookup_pr_for_handoff(workspace_path, recovered_entry, branch_name) do
        {:ok, pr} when is_map(pr) ->
          Logger.info("Recovering blocked review handoff after PR discovery: #{issue_context(issue)} branch=#{branch_name} pr=#{pr_url(pr)}")

          {:ok, move_blocked_issue_to_review_after_pr_discovery(state, issue.id, recovered_entry, pr)}

        miss ->
          retry_error = blocked_review_handoff_lookup_error(issue, branch_name, miss)

          {:ok,
           record_blocked_policy_attempt(
             state,
             issue.id,
             recovered_entry,
             :blocked_review_handoff,
             attempt,
             attempt_state,
             retry_error
           )}
      end
    else
      {:terminal, attempt, retry_error, attempt_state} ->
        {:ok,
         terminal_blocked_policy_attempt(
           state,
           issue.id,
           Map.get(state.blocked, issue.id),
           :blocked_review_handoff,
           attempt,
           attempt_state,
           retry_error
         )}

      true ->
        {:ok, state}

      _miss ->
        :miss
    end
  end

  defp guard_blocked_review_handoff_issue(%State{} = state, %Issue{} = issue) do
    with %{error: error} = blocked_entry <- Map.get(state.blocked, issue.id),
         false <- pending_review_handoff_for_issue?(state, issue.id),
         true <- review_handoff_pr_missing_error?(error),
         false <- policy_terminal_context?(blocked_entry, :blocked_review_handoff),
         guarded_entry <- refresh_blocked_review_handoff_entry(blocked_entry, issue) do
      {:ok, do_guard_blocked_review_handoff_issue(state, issue, guarded_entry)}
    else
      true -> {:ok, state}
      _miss -> :miss
    end
  end

  defp do_guard_blocked_review_handoff_issue(%State{} = state, %Issue{} = issue, blocked_entry) do
    session_id = running_entry_session_id(blocked_entry)

    case branch_name_and_workspace(blocked_entry) do
      {:ok, branch_name, workspace_path} ->
        guard_blocked_review_handoff_with_workspace(
          state,
          issue,
          blocked_entry,
          session_id,
          branch_name,
          workspace_path
        )

      :missing ->
        error = "issue moved to #{issue.state} without branch metadata for GitHub PR lookup"
        Logger.warning("Blocked review handoff remains blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")
        stop_and_block_review_handoff_issue(state, issue, blocked_entry, error)
    end
  end

  defp guard_blocked_review_handoff_with_workspace(state, issue, blocked_entry, session_id, branch_name, workspace_path) do
    case begin_policy_attempt(
           blocked_entry,
           :blocked_review_handoff,
           blocked_review_handoff_evidence(blocked_entry)
         ) do
      {:ok, attempt, attempt_state} ->
        apply_blocked_review_handoff_guard_lookup(
          state,
          issue,
          blocked_entry,
          session_id,
          branch_name,
          workspace_path,
          attempt,
          attempt_state
        )

      {:terminal, attempt, retry_error, attempt_state} ->
        terminal_blocked_policy_attempt(
          state,
          issue.id,
          blocked_entry,
          :blocked_review_handoff,
          attempt,
          attempt_state,
          retry_error
        )
    end
  end

  defp apply_blocked_review_handoff_guard_lookup(
         state,
         issue,
         blocked_entry,
         session_id,
         branch_name,
         workspace_path,
         attempt,
         attempt_state
       ) do
    case lookup_pr_for_handoff(workspace_path, blocked_entry, branch_name) do
      {:ok, pr} when is_map(pr) ->
        Logger.info("Guarding blocked review handoff after PR discovery: #{issue_context(issue)} branch=#{branch_name} pr=#{pr_url(pr)}")
        review_premature_handoff_pr(state, issue, blocked_entry, session_id, pr)

      miss ->
        error = blocked_review_handoff_lookup_error(issue, branch_name, miss)

        Logger.warning("Blocked review handoff remains blocked for issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{session_id}: #{error}")

        state
        |> stop_and_block_review_handoff_issue(issue, blocked_entry, error)
        |> record_blocked_policy_attempt(
          issue.id,
          blocked_entry,
          :blocked_review_handoff,
          attempt,
          attempt_state,
          error
        )
    end
  end

  defp pending_review_handoff_for_issue?(%State{pending_review_handoffs: pending}, issue_id)
       when is_binary(issue_id) do
    Enum.any?(pending, fn
      {_ref, %{issue_id: ^issue_id}} -> true
      _other -> false
    end)
  end

  defp pending_review_handoff_for_issue?(_state, _issue_id), do: false

  defp review_handoff_pr_missing_error?(error) when is_binary(error) do
    String.contains?(error, "agent-owned PR is required") and
      (String.contains?(error, "without discoverable GitHub PR") or
         String.contains?(error, "no GitHub PR found"))
  end

  defp review_handoff_pr_missing_error?(_error), do: false

  defp begin_policy_attempt(entry, context, evidence) do
    policy = Config.retry_policy(context)

    attempt_state =
      entry
      |> Map.get(:policy_attempts, %{})
      |> Map.get(context, %{})
      |> RetryPolicy.reset_on_progress(evidence)

    next_attempt = Map.get(attempt_state, :attempts, 0) + 1
    retry_error = Map.get(attempt_state, :last_error)

    if RetryPolicy.allow_attempt?(next_attempt, policy) do
      {:ok, next_attempt, attempt_state}
    else
      {:terminal, next_attempt, retry_error, attempt_state}
    end
  end

  defp record_blocked_policy_attempt(%State{} = state, issue_id, entry, context, attempt, attempt_state, error) do
    entry = Map.get(state.blocked, issue_id, entry)

    updated_entry =
      entry
      |> Map.put(:error, error)
      |> put_policy_attempt(context, Map.merge(attempt_state, %{attempts: attempt, last_error: error}))

    %{state | blocked: Map.put(state.blocked, issue_id, updated_entry)}
  end

  defp terminal_blocked_policy_attempt(%State{} = state, issue_id, entry, context, attempt, attempt_state, error) do
    entry = entry || %{}
    policy = Config.retry_policy(context)
    terminal_error = RetryPolicy.terminal_reason(policy, attempt, error)

    updated_entry =
      entry
      |> Map.put(:error, terminal_error)
      |> Map.put(:policy_terminal_context, context)
      |> put_policy_attempt(context, Map.merge(attempt_state, %{attempts: attempt, last_error: terminal_error}))

    %{state | blocked: Map.put(state.blocked, issue_id, updated_entry)}
  end

  defp put_policy_attempt(entry, context, attempt_state) do
    policy_attempts =
      entry
      |> Map.get(:policy_attempts, %{})
      |> Map.put(context, attempt_state)

    Map.put(entry, :policy_attempts, policy_attempts)
  end

  defp policy_terminal_context?(entry, context) when is_map(entry) do
    Map.get(entry, :policy_terminal_context) == context
  end

  defp policy_terminal_context?(_entry, _context), do: false

  defp blocked_review_handoff_lookup_error(%Issue{} = issue, branch_name, {:ok, nil}) do
    "issue moved to #{issue.state} without discoverable GitHub PR for branch #{branch_name} or linked PR attachments; agent-owned PR is required before handoff"
  end

  defp blocked_review_handoff_lookup_error(%Issue{} = issue, branch_name, {:error, reason}) do
    "issue moved to #{issue.state} but GitHub PR lookup failed for branch #{branch_name}: #{inspect(reason)}"
  end

  defp blocked_review_handoff_lookup_error(%Issue{} = issue, branch_name, _other) do
    "issue moved to #{issue.state} but GitHub PR lookup returned unexpected result for branch #{branch_name}"
  end

  defp refresh_blocked_review_handoff_entry(blocked_entry, %Issue{} = refreshed_issue) do
    Map.update(blocked_entry, :issue, refreshed_issue, fn
      %Issue{} = blocked_issue -> merge_refreshed_issue(blocked_issue, refreshed_issue)
      _other -> refreshed_issue
    end)
  end

  defp move_blocked_issue_to_review_after_pr_discovery(state, issue_id, blocked_entry, pr) do
    session_id = running_entry_session_id(blocked_entry)

    start_review_handoff_task(
      state,
      :normal,
      issue_id,
      blocked_entry,
      session_id,
      pr,
      nil,
      release_claim_on_completion: true
    )
  end

  defp release_completed_blocked_issue(%State{} = state, issue_id) do
    if MapSet.member?(state.completed, issue_id) do
      state
      |> release_issue_claim(issue_id)
      |> complete_issue(issue_id)
    else
      state
    end
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        stop_running_task(pid, ref)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    stall = Config.settings!().stall

    cond do
      not stall.enabled ->
        state

      stall.threshold_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now_ms = System.monotonic_time(:millisecond)

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_handle_stalled_issue(state_acc, issue_id, running_entry, now_ms, stall.threshold_ms)
        end)
    end
  end

  defp reconcile_stalled_review_handoffs(%State{} = state) do
    stall = Config.settings!().stall

    cond do
      not stall.enabled ->
        state

      stall.review_threshold_ms <= 0 ->
        state

      map_size(state.pending_review_handoffs) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.pending_review_handoffs, state, fn {ref, metadata}, state_acc ->
          maybe_handle_stalled_review_handoff(state_acc, ref, metadata, now, stall.review_threshold_ms)
        end)
    end
  end

  defp maybe_handle_stalled_review_handoff(state, ref, metadata, now, threshold_ms)
       when is_reference(ref) and is_map(metadata) do
    if Map.has_key?(state.pending_review_handoffs, ref) do
      handle_stalled_review_handoff(state, ref, metadata, now, threshold_ms)
    else
      state
    end
  end

  defp maybe_handle_stalled_review_handoff(state, _ref, _metadata, _now, _threshold_ms), do: state

  defp handle_stalled_review_handoff(state, ref, metadata, now, threshold_ms) do
    elapsed_ms = review_handoff_elapsed_ms(metadata, now)

    cond do
      not is_integer(elapsed_ms) or elapsed_ms < threshold_ms ->
        state

      elapsed_ms >= threshold_ms * 2 ->
        metadata = maybe_comment_on_review_handoff_stall_episode(ref, metadata, elapsed_ms, threshold_ms)
        recycle_stalled_review_handoff(state, ref, metadata, elapsed_ms)

      true ->
        metadata = maybe_comment_on_review_handoff_stall_episode(ref, metadata, elapsed_ms, threshold_ms)
        %{state | pending_review_handoffs: Map.put(state.pending_review_handoffs, ref, metadata)}
    end
  end

  defp recycle_stalled_review_handoff(state, ref, metadata, elapsed_ms) do
    issue_id = Map.get(metadata, :issue_id, "unknown")
    running_entry = Map.get(metadata, :running_entry, %{})
    issue = Map.get(metadata, :issue)
    issue_identifier = review_handoff_identifier(running_entry, issue) || issue_id
    session_id = Map.get(metadata, :session_id)
    pr = pr_url(Map.get(metadata, :pr))

    Logger.warning(
      "Review handoff stalled: issue_id=#{issue_id} issue_identifier=#{issue_identifier} " <>
        "session_id=#{session_id} pr=#{pr} elapsed_ms=#{elapsed_ms}; recycling through terminal review handoff path"
    )

    terminate_task(Map.get(metadata, :pid))
    Process.demonitor(ref, [:flush])

    state
    |> Map.put(:pending_review_handoffs, Map.delete(state.pending_review_handoffs, ref))
    |> finish_pending_review_handoff(metadata, {:error, {:review_handoff_stalled, elapsed_ms}})
  end

  defp maybe_comment_on_review_handoff_stall_episode(ref, metadata, elapsed_ms, threshold_ms) do
    if Map.get(metadata, :review_stall_comment_posted?, false) do
      metadata
    else
      comment_on_stalled_review_handoff(ref, metadata, elapsed_ms, threshold_ms)
      Map.put(metadata, :review_stall_comment_posted?, true)
    end
  end

  defp comment_on_stalled_review_handoff(ref, metadata, elapsed_ms, threshold_ms) do
    issue_id = Map.get(metadata, :issue_id)
    running_entry = Map.get(metadata, :running_entry, %{})
    issue = Map.get(metadata, :issue)
    identifier = review_handoff_identifier(running_entry, issue) || issue_id || "unknown"
    session_id = Map.get(metadata, :session_id)
    pr = pr_url(Map.get(metadata, :pr))
    body = stalled_review_handoff_comment(identifier, session_id, pr, elapsed_ms, threshold_ms)

    case tracker_for_review_handoff(metadata).create_comment(issue_id, body) do
      :ok ->
        :ok

      {:ok, _comment} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Failed to create stalled review-handoff comment for issue_id=#{issue_id} " <>
            "review_ref=#{inspect(ref)}: #{inspect(reason)}"
        )
    end
  rescue
    exception ->
      Logger.debug(
        "Failed to create stalled review-handoff comment for issue_id=#{Map.get(metadata, :issue_id)} " <>
          "review_ref=#{inspect(ref)}: #{Exception.message(exception)}"
      )
  end

  defp tracker_for_review_handoff(metadata) when is_map(metadata) do
    Map.get(metadata, :tracker, tracker_module())
  end

  defp stalled_review_handoff_comment(identifier, session_id, pr, elapsed_ms, threshold_ms) do
    elapsed_minutes = max(1, div(elapsed_ms + 59_999, 60_000))
    recycle_minutes = max(1, div(threshold_ms * 2 + 59_999, 60_000))

    """
    Symphony detected a stalled review handoff for #{identifier}.

    Reason: review handoff running for #{elapsed_minutes}m, session=#{session_id}, pr=#{pr}.
    Next action: will recycle the review handoff at #{recycle_minutes}m so the bounded review handoff policy can continue.
    """
    |> String.trim()
  end

  defp review_handoff_elapsed_ms(metadata, now) when is_map(metadata) do
    case Map.get(metadata, :started_at) do
      %DateTime{} = started_at ->
        max(0, DateTime.diff(now, started_at, :millisecond))

      started_at when is_binary(started_at) ->
        case DateTime.from_iso8601(started_at) do
          {:ok, timestamp, _offset} -> max(0, DateTime.diff(now, timestamp, :millisecond))
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_handle_stalled_issue(state, issue_id, running_entry, now_ms, threshold_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      handle_stalled_issue(state, issue_id, running_entry, now_ms, threshold_ms)
    end
  end

  defp handle_stalled_issue(state, issue_id, running_entry, now_ms, threshold_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now_ms)

    cond do
      not is_integer(elapsed_ms) or elapsed_ms < threshold_ms ->
        state

      elapsed_ms >= threshold_ms * 2 ->
        running_entry = maybe_comment_on_stall_episode(issue_id, running_entry, elapsed_ms, threshold_ms)
        recycle_stalled_issue(state, issue_id, running_entry, elapsed_ms)

      true ->
        running_entry = maybe_comment_on_stall_episode(issue_id, running_entry, elapsed_ms, threshold_ms)
        %{state | running: Map.put(state.running, issue_id, running_entry)}
    end
  end

  defp recycle_stalled_issue(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; recycling with retry backoff")

    next_attempt = next_retry_attempt_from_running(running_entry)

    state
    |> terminate_running_issue(issue_id, false)
    |> schedule_issue_retry(issue_id, next_attempt, %{
      identifier: identifier,
      error: "stalled for #{elapsed_ms}ms without codex progress",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_comment_on_stall_episode(issue_id, running_entry, elapsed_ms, threshold_ms) do
    if Map.get(running_entry, :stall_comment_posted?, false) do
      running_entry
    else
      comment_on_stalled_issue(issue_id, running_entry, elapsed_ms, threshold_ms)
      Map.put(running_entry, :stall_comment_posted?, true)
    end
  end

  defp comment_on_stalled_issue(issue_id, running_entry, elapsed_ms, threshold_ms) when is_binary(issue_id) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    attempt = next_retry_attempt_from_running(running_entry) || 1
    body = stalled_issue_comment(identifier, session_id, attempt, elapsed_ms, threshold_ms)

    case tracker_module().create_comment(issue_id, body) do
      :ok ->
        :ok

      {:ok, _comment} ->
        :ok

      {:error, reason} ->
        Logger.debug("Failed to create stalled-issue comment for issue_id=#{issue_id}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.debug("Failed to create stalled-issue comment for issue_id=#{issue_id}: #{Exception.message(exception)}")
  end

  defp comment_on_stalled_issue(_issue_id, _running_entry, _elapsed_ms, _threshold_ms), do: :ok

  defp stalled_issue_comment(identifier, session_id, attempt, elapsed_ms, threshold_ms) do
    elapsed_minutes = max(1, div(elapsed_ms + 59_999, 60_000))
    recycle_minutes = max(1, div(threshold_ms * 2 + 59_999, 60_000))

    """
    Symphony detected a stalled running agent for #{identifier}.

    Reason: no progress for #{elapsed_minutes}m, session=#{session_id}.
    Attempt count: #{attempt}.
    Next action: will recycle the agent at #{recycle_minutes}m without progress so the bounded retry policy can continue.
    """
    |> String.trim()
  end

  defp stall_elapsed_ms(running_entry, now_ms) when is_integer(now_ms) do
    case Map.get(running_entry, :last_progress_ms) do
      last_progress_ms when is_integer(last_progress_ms) ->
        max(0, now_ms - last_progress_ms)

      _ ->
        stall_elapsed_ms_from_datetime(running_entry, DateTime.utc_now())
    end
  end

  defp stall_elapsed_ms_from_datetime(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp stop_and_block_review_handoff_issue(
         %State{} = state,
         %Issue{} = issue,
         running_entry,
         error,
         tracker \\ tracker_module()
       ) do
    target_state = review_handoff_block_state()
    move_review_handoff_issue_to_block_state(issue.id, issue.identifier, target_state, tracker)

    running_entry =
      Map.update(running_entry, :issue, %{issue | state: target_state}, fn
        %Issue{} = running_issue -> %{running_issue | state: target_state}
        _other -> %{issue | state: target_state}
      end)

    stop_and_block_issue(state, issue.id, running_entry, error)
  end

  defp review_premature_handoff_pr(%State{} = state, %Issue{} = issue, running_entry, session_id, pr) do
    if pending_review_handoff_for_issue?(state, issue.id) do
      Logger.info("Skipping premature review handoff for issue_id=#{issue.id}; a review handoff is already pending")
      state
    else
      stopped_state = terminate_running_issue(state, issue.id, false)

      start_review_handoff_task(
        stopped_state,
        :premature,
        issue.id,
        running_entry,
        session_id,
        pr,
        issue
      )
    end
  end

  defp review_handoff_block_state do
    active_states = Config.settings!().tracker.active_states

    Enum.find(active_states, fn state -> normalize_issue_state(state) == "rework" end) ||
      Enum.find(active_states, "In Progress", fn state -> normalize_issue_state(state) == "in progress" end)
  end

  defp move_review_handoff_issue_to_block_state(issue_id, issue_identifier, target_state, tracker)
       when is_binary(issue_id) and is_binary(target_state) do
    case tracker.update_issue_state(issue_id, target_state) do
      :ok ->
        Logger.info("Moved premature review handoff back to #{target_state}: issue_id=#{issue_id} issue_identifier=#{issue_identifier}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to move premature review handoff back to #{target_state}: issue_id=#{issue_id} issue_identifier=#{issue_identifier} reason=#{inspect(reason)}")
        :ok

      other ->
        Logger.warning("Failed to move premature review handoff back to #{target_state}: issue_id=#{issue_id} issue_identifier=#{issue_identifier} result=#{inspect(other)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to move premature review handoff back to #{target_state}: issue_id=#{issue_id} issue_identifier=#{issue_identifier} reason=#{Exception.message(exception)}")
      :ok
  end

  defp maybe_block_repeated_fingerprint(%State{} = state, issue_id, running_entry) do
    config = Config.settings!().agent

    cond do
      fingerprint_limit_reached?(
        Map.get(running_entry, :test_failure_fingerprint_streak, 0),
        config.same_test_failure_fingerprint_limit
      ) ->
        stop_and_block_issue(
          state,
          issue_id,
          running_entry,
          "repeated test failure fingerprint reached limit #{config.same_test_failure_fingerprint_limit}"
        )

      fingerprint_limit_reached?(
        Map.get(running_entry, :review_fingerprint_streak, 0),
        config.same_review_fingerprint_limit
      ) ->
        stop_and_block_issue(
          state,
          issue_id,
          running_entry,
          "repeated review fingerprint reached limit #{config.same_review_fingerprint_limit}"
        )

      true ->
        state
    end
  end

  defp fingerprint_limit_reached?(streak, limit)
       when is_integer(streak) and is_integer(limit) and limit > 0,
       do: streak >= limit

  defp fingerprint_limit_reached?(_streak, _limit), do: false

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    comment_on_blocked_issue(issue_id, running_entry, error)

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp comment_on_blocked_issue(issue_id, running_entry, error) when is_binary(issue_id) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    body = Config.blocked_issue_comment(identifier, error)

    case tracker_module().create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Failed to create blocked-issue comment for issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.debug("Failed to create blocked-issue comment for issue_id=#{issue_id}: #{Exception.message(exception)}")
      :ok
  end

  defp comment_on_blocked_issue(_issue_id, _running_entry, _error), do: :ok

  defp comment_on_quarantined_workspace(issue_id, running_entry, %{
         workspace: workspace,
         quarantine: quarantine,
         dirty_status: dirty_status
       })
       when is_binary(issue_id) and is_binary(workspace) and is_binary(quarantine) and is_binary(dirty_status) do
    identifier = Map.get(running_entry, :identifier, issue_id)

    body = """
    Symphony quarantined a dirty workspace before rerunning #{identifier}.

    Workspace: #{workspace}
    Quarantine: #{quarantine}

    Git status --porcelain:
    #{String.trim(dirty_status)}
    """

    case tracker_module().create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Failed to create dirty-workspace quarantine comment for issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.debug("Failed to create dirty-workspace quarantine comment for issue_id=#{issue_id}: #{Exception.message(exception)}")
      :ok
  end

  defp comment_on_quarantined_workspace(_issue_id, _running_entry, _quarantine), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp record_unroutable_issues(%State{} = state, issues) when is_list(issues) do
    settings = Config.settings!()
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    detected_at = DateTime.utc_now()
    previous_by_issue_id = Map.new(state.unroutable, &{Map.get(&1, :issue_id), &1})

    unroutable =
      issues
      |> sort_issues_for_dispatch()
      |> Enum.flat_map(fn issue ->
        unroutable_issue_entry(
          issue,
          state,
          settings,
          active_states,
          terminal_states,
          detected_at,
          previous_by_issue_id
        )
      end)

    %{state | unroutable: unroutable}
  end

  defp record_unroutable_issues(state, _issues), do: state

  defp unroutable_issue_entry(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         %State{} = state,
         settings,
         active_states,
         terminal_states,
         detected_at,
         previous_by_issue_id
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    if unroutable_candidate_issue?(issue, state, active_states, terminal_states) do
      build_unroutable_issue_entry(issue, settings, detected_at, previous_by_issue_id)
    else
      []
    end
  end

  defp unroutable_issue_entry(
         _issue,
         _state,
         _settings,
         _active_states,
         _terminal_states,
         _detected_at,
         _previous_by_issue_id
       ),
       do: []

  defp unroutable_candidate_issue?(
         %Issue{state: state_name} = issue,
         %State{} = state,
         active_states,
         terminal_states
       ) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !tracked_issue?(state, issue.id)
  end

  defp build_unroutable_issue_entry(%Issue{} = issue, settings, detected_at, previous_by_issue_id) do
    case repository_route_status(issue, settings) do
      :ok ->
        []

      {:error, reason, details} ->
        [unroutable_issue_payload(issue, reason, details, detected_at, previous_by_issue_id)]
    end
  end

  defp unroutable_issue_payload(%Issue{} = issue, reason, details, detected_at, previous_by_issue_id) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      project_name: issue.project_name,
      project_slug: issue.project_slug,
      reason: Atom.to_string(reason),
      message: repository_route_status_message(reason, details),
      details: details,
      detected_at: previous_detected_at(previous_by_issue_id, issue.id, detected_at)
    }
  end

  defp tracked_issue?(%State{} = state, issue_id) do
    MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id) or
      Map.has_key?(state.blocked, issue_id)
  end

  defp previous_detected_at(previous_by_issue_id, issue_id, fallback) when is_map(previous_by_issue_id) do
    previous_by_issue_id
    |> Map.get(issue_id, %{})
    |> Map.get(:detected_at, fallback)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      issue_routable_to_repository?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_repository?(%Issue{} = issue) do
    settings = Config.settings!()

    case repository_route_status(issue, settings) do
      :ok ->
        true

      {:error, reason, details} ->
        log_repository_route_skip(issue, reason, details)
        false
    end
  end

  defp repository_route_status(%Issue{} = issue, settings) do
    if settings.tracker.all_projects do
      all_projects_repository_route_status(issue, settings)
    else
      :ok
    end
  end

  defp all_projects_repository_route_status(%Issue{} = issue, settings) do
    if RepositoryResolver.repository_hint?(issue),
      do: repository_hint_route_status(issue, settings),
      else: unique_project_route_status(issue, settings)
  end

  defp repository_hint_route_status(%Issue{} = issue, settings) do
    case RepositoryResolver.resolve(issue, settings) do
      {:ok, %{slug: repo_slug, name: repo_name}}
      when is_binary(repo_slug) and is_binary(repo_name) ->
        if linear_project_matches_repository?(issue, repo_slug, repo_name, settings) do
          :ok
        else
          {:error, :repository_project_mismatch, %{repo_slug: repo_slug}}
        end

      {:error, reason} ->
        {:error, :repository_hint_error, %{error: inspect(reason)}}

      _invalid ->
        {:error, :repository_hint_error, %{error: "invalid repository resolver response"}}
    end
  end

  defp unique_project_route_status(%Issue{} = issue, settings) do
    case RepositoryResolver.project_route_slug(issue, settings) do
      {:ok, _repo_slug} ->
        :ok

      :none ->
        {:error, :missing_project_route, %{}}

      {:error, {:ambiguous_repository_project_routes, repo_slugs}} ->
        {:error, :ambiguous_project_route, %{repo_slugs: repo_slugs}}
    end
  end

  defp log_repository_route_skip(%Issue{} = issue, reason, details) do
    Logger.debug(
      "Skipping dispatch; #{repository_route_status_message(reason, details)} for #{issue_context(issue)} " <>
        "project_name=#{inspect(issue.project_name)} project_slug=#{inspect(issue.project_slug)}"
    )
  end

  defp repository_route_status_message(:missing_project_route, _details) do
    "Linear project is not mapped to a repository; add repository.project_routes or a trusted GitHub repo URL"
  end

  defp repository_route_status_message(:ambiguous_project_route, %{repo_slugs: repo_slugs}) do
    "Linear project matches multiple repository routes: #{Enum.join(repo_slugs, ", ")}"
  end

  defp repository_route_status_message(:repository_project_mismatch, %{repo_slug: repo_slug}) do
    "repository hint resolves to #{repo_slug}, but the Linear project does not match that repository route"
  end

  defp repository_route_status_message(:repository_hint_error, %{error: error}) do
    "repository hint could not be resolved: #{error}"
  end

  defp repository_route_status_message(reason, details) do
    "repository route check failed: #{inspect(reason)} #{inspect(details)}"
  end

  defp linear_project_matches_repository?(%Issue{} = issue, repo_slug, repo_name, settings)
       when is_binary(repo_slug) and is_binary(repo_name) do
    route_tokens = repository_project_route_tokens(settings, repo_slug)

    if route_tokens == [] do
      linear_project_matches_repository_name?(issue, repo_name)
    else
      issue
      |> issue_project_route_tokens()
      |> Enum.any?(fn project_token ->
        Enum.any?(route_tokens, &(project_token == &1))
      end)
    end
  end

  defp linear_project_matches_repository_name?(%Issue{} = issue, repo_name) when is_binary(repo_name) do
    repo_token = route_token(repo_name)

    if repo_token == "" do
      false
    else
      issue
      |> issue_project_route_tokens()
      |> Enum.any?(fn project_token ->
        project_token == repo_token or String.starts_with?(project_token, repo_token)
      end)
    end
  end

  defp repository_project_route_tokens(settings, repo_slug) when is_binary(repo_slug) do
    settings
    |> RepositoryRoutes.effective_project_routes()
    |> RepositoryRoutes.project_route_aliases(repo_slug)
    |> Enum.map(&route_token/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp issue_project_route_tokens(%Issue{} = issue) do
    [issue.project_name, issue.project_slug]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&route_token/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp route_token(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp route_token(_value), do: ""

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         agent_opts \\ []
       ) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        case maybe_start_existing_open_pr_handoff(state, refreshed_issue) do
          {:handoff, state} -> state
          :dispatch -> do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, agent_opts)
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, agent_opts) do
    recipient = self()
    preferred_worker_host = preferred_worker_host_for_issue(issue, preferred_worker_host)
    agent_opts = maybe_allow_dirty_existing_workspace_for_active_resume(agent_opts, issue, attempt)

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        case claim_issue_for_dispatch(issue, &Tracker.update_issue_state/2) do
          {:ok, claimed_issue} ->
            spawn_issue_on_worker_host(
              state,
              claimed_issue,
              attempt,
              recipient,
              worker_host,
              agent_opts
            )

          {:error, reason} ->
            Logger.warning("Skipping dispatch after claim failure for #{issue_context(issue)}: #{inspect(reason)}")
            block_issue_before_dispatch(state, issue, "failed to claim issue before dispatch: #{inspect(reason)}")
        end
    end
  end

  defp maybe_start_existing_open_pr_handoff(%State{} = state, %Issue{} = issue) do
    case lookup_open_pr_for_dispatch(issue) do
      {:ok, %{} = pr} ->
        start_existing_open_pr_handoff(state, issue, pr)

      {:ok, nil} ->
        :dispatch

      {:error, {:ambiguous_open_issue_pull_requests, _urls} = reason} ->
        error = "ambiguous open GitHub PRs found before dispatch: #{inspect(reason)}"
        Logger.warning("Blocking dispatch for #{issue_context(issue)}: #{error}")
        {:handoff, block_issue_before_dispatch(state, issue, error)}

      {:error, reason} ->
        Logger.warning("Continuing dispatch for #{issue_context(issue)}; open PR guard lookup failed: #{inspect(reason)}")

        :dispatch
    end
  end

  defp lookup_open_pr_for_dispatch(%Issue{} = issue) do
    lookup_module = github_pr_lookup_module()

    if open_issue_pr_lookup_available?() do
      case RepositoryResolver.resolve(issue, Config.settings!()) do
        {:ok, %{slug: repo}} when is_binary(repo) and repo != "" ->
          lookup_module.lookup_open_issue_pull_request(
            repo,
            issue.identifier,
            issue.url,
            issue.branch_name,
            issue_attachment_urls(issue)
          )

        {:ok, _context} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, {:repository_resolve_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp open_issue_pr_lookup_available? do
    github_pr_lookup_module()
    |> module_exports?(:lookup_open_issue_pull_request, 5)
  end

  defp start_existing_open_pr_handoff(%State{} = state, %Issue{} = issue, %{} = pr, opts \\ []) do
    case Workspace.create_for_issue(issue, nil, allow_dirty_existing_workspace: true) do
      {:ok, workspace_path} ->
        reason = Keyword.get(opts, :reason, :dispatch)
        session_id = open_pr_handoff_session_id(reason)
        running_entry = dispatch_open_pr_running_entry(issue, workspace_path, pr, session_id)

        Logger.info(
          "Open PR discovered #{open_pr_handoff_log_context(reason)} for #{issue_context(issue)}; " <>
            "skipping implementation worker and starting review handoff pr=#{pr_url(pr)}"
        )

        state =
          %{
            state
            | claimed: MapSet.put(state.claimed, issue.id),
              retry_attempts: Map.delete(state.retry_attempts, issue.id)
          }

        {:handoff, start_review_handoff_task(state, :normal, issue.id, running_entry, session_id, pr, nil, release_claim_on_completion: Keyword.get(opts, :release_claim_on_completion, false))}

      {:error, reason} ->
        error = "failed to prepare workspace for existing open PR before dispatch: #{inspect(reason)}"
        Logger.warning("Blocking dispatch for #{issue_context(issue)}: #{error}")
        {:handoff, block_issue_before_dispatch(state, issue, error)}
    end
  end

  defp dispatch_open_pr_running_entry(%Issue{} = issue, workspace_path, pr, session_id) do
    now_ms = System.monotonic_time(:millisecond)

    %{
      pid: nil,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      branch_name: pr["headRefName"] || issue.branch_name,
      worker_host: nil,
      workspace_path: workspace_path,
      session_id: session_id,
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      started_at: DateTime.utc_now(),
      last_progress_ms: now_ms,
      stall_comment_posted?: false
    }
  end

  defp open_pr_handoff_session_id(:polling_reconcile), do: "polling-open-pr-reconcile"
  defp open_pr_handoff_session_id(:blocked_done_sync_reconcile), do: "blocked-done-sync-open-pr-reconcile"
  defp open_pr_handoff_session_id(_reason), do: "dispatch-open-pr-guard"

  defp open_pr_handoff_log_context(:polling_reconcile), do: "during active issue reconcile"
  defp open_pr_handoff_log_context(:blocked_done_sync_reconcile), do: "during Done sync blocked issue recovery"
  defp open_pr_handoff_log_context(_reason), do: "before dispatch"

  defp claim_issue_for_dispatch(%Issue{state: state_name} = issue, state_updater)
       when is_function(state_updater, 2) do
    if normalize_issue_state(state_name) == "todo" do
      case state_updater.(issue.id, "In Progress") do
        :ok -> {:ok, %{issue | state: "In Progress"}}
        {:error, reason} -> {:error, {:claim_issue_failed, reason}}
      end
    else
      {:ok, issue}
    end
  end

  defp new_running_entry(%Issue{} = issue, pid, ref, worker_host, attempt, agent_opts, now_ms \\ System.monotonic_time(:millisecond)) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      workspace_path: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: normalize_retry_attempt(attempt),
      continuation_count: normalize_continuation_count(Keyword.get(agent_opts, :continuation_count)),
      started_at: DateTime.utc_now(),
      last_progress_ms: now_ms,
      stall_comment_posted?: false
    }
  end

  defp block_issue_before_dispatch(%State{} = state, %Issue{} = issue, error) do
    block_issue_from_entry(
      state,
      issue.id,
      %{
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        last_codex_timestamp: nil
      },
      error
    )
  end

  defp spawn_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         agent_opts
       ) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           agent_runner_module().run(
             issue,
             recipient,
             [attempt: attempt, worker_host: worker_host] ++ agent_opts
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        now_ms = System.monotonic_time(:millisecond)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(
            state.running,
            issue.id,
            new_running_entry(issue, pid, ref, worker_host, attempt, agent_opts, now_ms)
          )

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    pr_number = pick_retry_pr_number(previous_retry, metadata)
    pr_url = pick_retry_pr_url(previous_retry, metadata)
    delay_type = pick_retry_delay_type(previous_retry, metadata)
    continuation_count = pick_retry_continuation_count(previous_retry, metadata)
    policy_context = pick_retry_policy_context(previous_retry, metadata)
    policy = Config.retry_policy(policy_context)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    if RetryPolicy.allow_attempt?(next_attempt, policy) do
      delay_ms = RetryPolicy.backoff_ms(next_attempt, policy)
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms

      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue_id, %{
              attempt: next_attempt,
              timer_ref: timer_ref,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              identifier: identifier,
              error: error,
              pr_number: pr_number,
              pr_url: pr_url,
              worker_host: worker_host,
              workspace_path: workspace_path,
              delay_type: delay_type,
              policy_context: policy_context,
              continuation_count: continuation_count
            })
      }
    else
      terminal_error = RetryPolicy.terminal_reason(policy, next_attempt, error)

      Logger.warning(
        "Retry attempts exhausted for issue_id=#{issue_id} issue_identifier=#{identifier} " <>
          "context=#{policy_context} attempt=#{next_attempt}: #{terminal_error}"
      )

      block_issue_from_entry(
        state,
        issue_id,
        %{
          identifier: identifier,
          issue: nil,
          worker_host: worker_host,
          workspace_path: workspace_path,
          session_id: nil,
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil
        },
        terminal_error
      )
    end
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          pr_number: Map.get(retry_entry, :pr_number),
          pr_url: Map.get(retry_entry, :pr_url),
          delay_type: Map.get(retry_entry, :delay_type),
          policy_context: Map.get(retry_entry, :policy_context),
          continuation_count: Map.get(retry_entry, :continuation_count)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp blocked_issue_worker_host(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id, %{})
    |> Map.get(:worker_host)
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp run_dirty_workspace_cleanup do
    case Workspace.cleanup_dirty_workspaces() do
      {:ok, %{removed: removed}} when removed != [] ->
        Logger.info("Cleaned expired dirty workspaces count=#{length(removed)}")

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Skipping dirty workspace cleanup: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      agent_opts =
        if continuation_retry?(metadata) do
          [
            allow_dirty_existing_workspace: true,
            continuation_count: metadata[:continuation_count]
          ]
        else
          []
        end

      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], agent_opts)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp normalize_continuation_count(count) when is_integer(count) and count > 0, do: count
  defp normalize_continuation_count(_count), do: 0

  defp next_continuation_count_from_running(running_entry) do
    normalize_continuation_count(Map.get(running_entry, :continuation_count)) + 1
  end

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_pr_number(previous_retry, metadata) do
    metadata[:pr_number] || Map.get(previous_retry, :pr_number)
  end

  defp pick_retry_pr_url(previous_retry, metadata) do
    metadata[:pr_url] || Map.get(previous_retry, :pr_url)
  end

  defp pick_retry_delay_type(previous_retry, metadata) do
    metadata[:delay_type] || Map.get(previous_retry, :delay_type)
  end

  defp pick_retry_continuation_count(previous_retry, metadata) do
    metadata[:continuation_count] || Map.get(previous_retry, :continuation_count)
  end

  defp pick_retry_policy_context(previous_retry, metadata) do
    metadata[:policy_context] ||
      Map.get(previous_retry, :policy_context) ||
      default_retry_policy_context(metadata)
  end

  defp default_retry_policy_context(metadata) do
    if continuation_retry?(metadata), do: :max_turn_continuation, else: :agent_failure
  end

  defp continuation_retry?(metadata) when is_map(metadata) do
    metadata[:delay_type] == :continuation
  end

  defp maybe_allow_dirty_existing_workspace_for_active_resume(agent_opts, %Issue{} = issue, _attempt) do
    if already_active_resume_issue?(issue) do
      Keyword.put(agent_opts, :allow_dirty_existing_workspace, true)
    else
      agent_opts
    end
  end

  defp already_active_resume_issue?(%Issue{state: state_name}) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    normalized_state != "todo" and
      active_issue_state?(state_name, active_state_set())
  end

  defp already_active_resume_issue?(_issue), do: false

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_for_issue(%Issue{}, preferred_worker_host)
       when is_binary(preferred_worker_host) and preferred_worker_host != "" do
    preferred_worker_host
  end

  defp preferred_worker_host_for_issue(%Issue{} = issue, _preferred_worker_host) do
    HermesDelegation.preferred_worker_host(issue, Config.settings!().worker.ssh_hosts)
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          branch_name: snapshot_entry_branch_name(metadata),
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          pr_number: Map.get(retry, :pr_number),
          pr_url: Map.get(retry, :pr_url)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          branch_name: snapshot_entry_branch_name(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    reviewing =
      state.pending_review_handoffs
      |> Enum.map(fn {_ref, metadata} ->
        review_handoff_snapshot_entry(metadata)
      end)

    {:reply,
     %{
       running: running,
       reviewing: reviewing,
       landing: state.landing_queue || [],
       retrying: retrying,
       blocked: blocked,
       unroutable: state.unroutable,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp snapshot_entry_branch_name(%{issue: %Issue{branch_name: branch_name}}) do
    branch_name
  end

  defp snapshot_entry_branch_name(_metadata), do: nil

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp review_handoff_snapshot_entry(metadata) when is_map(metadata) do
    running_entry = Map.get(metadata, :running_entry, %{})
    issue = Map.get(metadata, :issue)

    %{
      issue_id: Map.get(metadata, :issue_id) || issue_id_from_review_issue(issue),
      identifier: review_handoff_identifier(running_entry, issue),
      pr_url: pr_url(Map.get(metadata, :pr)),
      mode: Map.get(metadata, :mode),
      session_id: Map.get(metadata, :session_id),
      started_at: Map.get(metadata, :started_at),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }
  end

  defp issue_id_from_review_issue(%Issue{id: issue_id}), do: issue_id
  defp issue_id_from_review_issue(_issue), do: nil

  defp review_handoff_identifier(%{identifier: identifier}, _issue) when is_binary(identifier), do: identifier
  defp review_handoff_identifier(_running_entry, %Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp review_handoff_identifier(_running_entry, _issue), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_running_entry =
      running_entry
      |> Map.merge(%{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        last_progress_ms: System.monotonic_time(:millisecond),
        stall_comment_posted?: false
      })
      |> record_codex_fingerprint(update)

    {
      updated_running_entry,
      token_delta
    }
  end

  defp record_codex_fingerprint(running_entry, update) do
    case codex_fingerprint_signal(update) do
      {:review, text} ->
        record_fingerprint(
          running_entry,
          text,
          :last_review_fingerprint,
          :review_fingerprint_streak
        )

      {:test_failure, text} ->
        record_fingerprint(
          running_entry,
          text,
          :last_test_failure_fingerprint,
          :test_failure_fingerprint_streak
        )

      nil ->
        running_entry
    end
  end

  defp record_fingerprint(running_entry, text, last_key, streak_key) do
    case fingerprint_text(text) do
      "" ->
        running_entry

      fingerprint ->
        streak =
          if Map.get(running_entry, last_key) == fingerprint do
            Map.get(running_entry, streak_key, 0) + 1
          else
            1
          end

        running_entry
        |> Map.put(last_key, fingerprint)
        |> Map.put(streak_key, streak)
    end
  end

  defp codex_fingerprint_signal(%{event: event} = update)
       when event in [:turn_failed, :turn_ended_with_error, :startup_failed] do
    {:test_failure, inspect(Map.get(update, :payload) || Map.get(update, :raw) || update)}
  end

  defp codex_fingerprint_signal(%{event: :notification, payload: %{} = payload}) do
    case map_value(payload, ["method", :method]) do
      "codex/event/exec_command_end" ->
        exec_command_failure_fingerprint(payload)

      method
      when method in [
             "codex/event/agent_message_delta",
             "codex/event/agent_message_content_delta",
             "item/agentMessage/delta"
           ] ->
        review_message_fingerprint(payload)

      _ ->
        nil
    end
  end

  defp codex_fingerprint_signal(_update), do: nil

  defp exec_command_failure_fingerprint(payload) do
    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, [:params, :msg, :exit_code]) ||
        map_path(payload, ["params", "msg", "exitCode"]) ||
        map_path(payload, [:params, :msg, :exitCode])

    if nonzero_exit_code?(exit_code) do
      command =
        map_path(payload, ["params", "msg", "command"]) ||
          map_path(payload, [:params, :msg, :command]) ||
          map_path(payload, ["params", "msg", "parsed_cmd"]) ||
          map_path(payload, [:params, :msg, :parsed_cmd]) ||
          "unknown command"

      {:test_failure, "#{normalize_command(command)} exit #{exit_code}"}
    end
  end

  defp review_message_fingerprint(payload) do
    text =
      map_path(payload, ["params", "msg", "delta"]) ||
        map_path(payload, [:params, :msg, :delta]) ||
        map_path(payload, ["params", "delta"]) ||
        map_path(payload, [:params, :delta]) ||
        map_path(payload, ["params", "text"]) ||
        map_path(payload, [:params, :text])

    if review_signal_text?(text) do
      {:review, text}
    end
  end

  defp review_signal_text?(text) when is_binary(text) do
    normalized = normalize_fingerprint_text(text)

    String.length(normalized) >= 20 and
      String.match?(
        normalized,
        ~r/(request changes|changes requested|review|needs fix|fix required|修正|差し戻し|再レビュー)/
      )
  end

  defp review_signal_text?(_text), do: false

  defp fingerprint_text(text) do
    normalized = normalize_fingerprint_text(text)

    if normalized == "" do
      ""
    else
      :crypto.hash(:sha256, normalized)
      |> Base.encode16(case: :lower)
    end
  end

  defp normalize_fingerprint_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  defp normalize_fingerprint_text(text) when is_list(text), do: normalize_fingerprint_text(to_string(text))
  defp normalize_fingerprint_text(nil), do: ""
  defp normalize_fingerprint_text(text), do: normalize_fingerprint_text(inspect(text))

  defp nonzero_exit_code?(exit_code) when is_integer(exit_code), do: exit_code != 0

  defp nonzero_exit_code?(exit_code) when is_binary(exit_code) do
    case Integer.parse(exit_code) do
      {0, ""} -> false
      {_code, ""} -> true
      _ -> false
    end
  end

  defp nonzero_exit_code?(_exit_code), do: false

  defp normalize_command(command) when is_binary(command), do: command
  defp normalize_command(command) when is_list(command), do: Enum.join(command, " ")
  defp normalize_command(command), do: inspect(command)

  defp map_path(value, []), do: value

  defp map_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next_value} -> map_path(next_value, rest)
      :error -> nil
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(value, keys) when is_map(value) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(value, key) end)
  end

  defp map_value(_value, _keys), do: nil

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp preserve_orchestrator_state(%State{} = state, operation, fun) when is_function(fun, 1) do
    fun.(state)
  rescue
    error ->
      Logger.error(
        "Orchestrator #{operation} crashed; preserving orchestrator state: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      state
  catch
    kind, reason ->
      Logger.error(
        "Orchestrator #{operation} aborted (#{inspect(kind)}); preserving orchestrator state: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      state
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
