defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @issue_entry_order [:running, :reviewing, :retry, :blocked, :unroutable]
  @issue_status_order [
    running: "running",
    reviewing: "reviewing",
    retry: "retrying",
    blocked: "blocked",
    unroutable: "unroutable"
  ]
  @workspace_entry_order [:running, :reviewing, :retry, :blocked]
  @recent_event_entry_order [:running, :blocked]

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            reviewing: length(Map.get(snapshot, :reviewing, [])),
            landing: length(Map.get(snapshot, :landing, [])),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            unroutable: length(Map.get(snapshot, :unroutable, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          reviewing: Enum.map(Map.get(snapshot, :reviewing, []), &reviewing_entry_payload/1),
          landing: Enum.map(Map.get(snapshot, :landing, []), &landing_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          unroutable: Enum.map(Map.get(snapshot, :unroutable, []), &unroutable_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          runtime_freshness: Map.get(snapshot, :runtime_freshness)
        }
        |> maybe_put_dirty_workspace_cleanup(snapshot)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        entries = issue_entries(snapshot, issue_identifier)

        if issue_entries_empty?(entries) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, entries)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_entries(snapshot, issue_identifier) do
    %{
      running: Enum.find(snapshot.running, &(&1.identifier == issue_identifier)),
      reviewing: Enum.find(Map.get(snapshot, :reviewing, []), &(&1.identifier == issue_identifier)),
      retry: Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier)),
      blocked: Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier)),
      unroutable: Enum.find(Map.get(snapshot, :unroutable, []), &(&1.identifier == issue_identifier))
    }
  end

  defp maybe_put_dirty_workspace_cleanup(payload, snapshot) do
    case Map.get(snapshot, :dirty_workspace_cleanup) do
      nil -> payload
      cleanup -> Map.put(payload, :dirty_workspace_cleanup, cleanup)
    end
  end

  defp issue_entries_empty?(entries) do
    entries
    |> Map.values()
    |> Enum.all?(&is_nil/1)
  end

  defp issue_payload_body(issue_identifier, entries) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(entries),
      status: issue_status(entries),
      workspace: %{
        path: workspace_path(issue_identifier, entries),
        host: workspace_host(entries)
      },
      attempts: attempts_payload(entries),
      running: entry_payload(entries, :running, &running_issue_payload/1),
      reviewing: entry_payload(entries, :reviewing, &reviewing_issue_payload/1),
      retry: entry_payload(entries, :retry, &retry_issue_payload/1),
      blocked: entry_payload(entries, :blocked, &blocked_issue_payload/1),
      unroutable: entry_payload(entries, :unroutable, &unroutable_issue_payload/1),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(recent_event_entry(entries)),
      last_error: last_error(entries),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(entries) do
    entries
    |> ordered_issue_entries()
    |> Enum.find_value(&entry_issue_id/1)
  end

  defp ordered_issue_entries(entries), do: Enum.map(@issue_entry_order, &Map.get(entries, &1))
  defp entry_issue_id(nil), do: nil
  defp entry_issue_id(entry), do: Map.get(entry, :issue_id)

  defp attempts_payload(entries) do
    retry = Map.get(entries, :retry)

    %{
      restart_count: restart_count(retry),
      current_retry_attempt: retry_attempt(retry)
    }
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(entries) do
    Enum.find_value(@issue_status_order, fn {key, status} ->
      if Map.get(entries, key), do: status
    end)
  end

  defp entry_payload(entries, key, mapper) do
    case Map.get(entries, key) do
      nil -> nil
      entry -> mapper.(entry)
    end
  end

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp reviewing_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      pr_url: Map.get(entry, :pr_url),
      mode: entry.mode && to_string(entry.mode),
      session_id: entry.session_id,
      started_at: iso8601(entry.started_at),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp landing_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier),
      title: Map.get(entry, :title),
      queue_position: Map.get(entry, :queue_position),
      queue_total: Map.get(entry, :queue_total),
      planned_action: Map.get(entry, :planned_action),
      status: Map.get(entry, :status),
      repository: Map.get(entry, :repository),
      pr_url: Map.get(entry, :pr_url),
      pr_state: Map.get(entry, :pr_state),
      draft: Map.get(entry, :draft),
      mergeability: Map.get(entry, :mergeability),
      review_decision: Map.get(entry, :review_decision),
      head_branch: Map.get(entry, :head_branch),
      head_sha: Map.get(entry, :head_sha),
      blocker: Map.get(entry, :blocker),
      dry_run_comment_exists: Map.get(entry, :dry_run_comment_exists),
      plan_id: Map.get(entry, :plan_id)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp unroutable_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      project_name: Map.get(entry, :project_name),
      project_slug: Map.get(entry, :project_slug),
      reason: Map.get(entry, :reason),
      message: Map.get(entry, :message),
      details: Map.get(entry, :details, %{}),
      detected_at: iso8601(Map.get(entry, :detected_at))
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp reviewing_issue_payload(reviewing) do
    %{
      pr_url: Map.get(reviewing, :pr_url),
      mode: reviewing.mode && to_string(reviewing.mode),
      session_id: reviewing.session_id,
      started_at: iso8601(reviewing.started_at),
      worker_host: Map.get(reviewing, :worker_host),
      workspace_path: Map.get(reviewing, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp unroutable_issue_payload(unroutable), do: unroutable_entry_payload(unroutable)

  defp workspace_path(issue_identifier, entries) do
    first_entry_value(entries, @workspace_entry_order, :workspace_path) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(entries), do: first_entry_value(entries, @workspace_entry_order, :worker_host)

  defp recent_event_entry(entries), do: first_entry(entries, @recent_event_entry_order)

  defp last_error(entries) do
    first_entry_value(entries, [:blocked, :retry], :error) ||
      first_entry_value(entries, [:unroutable], :message)
  end

  defp first_entry(entries, keys), do: Enum.find_value(keys, &Map.get(entries, &1))

  defp first_entry_value(entries, keys, field) do
    keys
    |> Enum.map(&Map.get(entries, &1))
    |> Enum.find_value(&entry_value(&1, field))
  end

  defp entry_value(nil, _field), do: nil
  defp entry_value(entry, field), do: Map.get(entry, field)

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
