defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  defmodule FakeGitHubPrLookupNone do
    def lookup_workspace_head(_workspace_path, _branch_name), do: {:ok, nil}
  end

  defmodule FakeGitHubPrLookupFound do
    def lookup_workspace_head(_workspace_path, _branch_name), do: {:ok, %{"number" => 123, "url" => "https://example.org/pull/123"}}
  end

  defmodule FakeGitHubPrLookupError do
    def lookup_workspace_head(_workspace_path, _branch_name), do: {:error, :missing_auth}
  end

  defmodule FakeGitHubPrLookupUnexpected do
    def lookup_workspace_head(_workspace_path, _branch_name), do: :unexpected
  end

  defmodule FakeGitHubPrLookupLinkedPrFallback do
    def lookup_workspace_handoff_pr(_workspace_path, branch_name, attachment_urls) do
      if "https://github.example/pull/79" in attachment_urls do
        {:ok,
         %{
           "number" => 79,
           "url" => "https://github.example/pull/79",
           "headRefName" => "feature/actual-pr",
           "__symphonyLookupSource" => "linked_pull_request",
           "__symphonyExpectedBranch" => branch_name
         }}
      else
        {:ok, nil}
      end
    end

    def lookup_workspace_head(_workspace_path, _branch_name), do: {:ok, nil}
  end

  defmodule FakeGitHubPrLookupMergedLinkedPr do
    def lookup_merged_linked_pull_request("octo/repo", attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_pr_lookup_called, attachment_urls})

        _ ->
          :ok
      end

      if "https://github.com/octo/repo/pull/200" in attachment_urls do
        {:ok,
         %{
           "number" => 200,
           "url" => "https://github.com/octo/repo/pull/200",
           "headRefName" => "lab-379-fix",
           "state" => "MERGED",
           "mergedAt" => "2026-06-09T01:42:42Z"
         }}
      else
        {:ok, nil}
      end
    end
  end

  defmodule FakeGitHubPrPublisherError do
    def publish_workspace(_workspace_path, _branch_name, _issue), do: {:error, :publish_blocked}
  end

  defmodule FakeReviewRunnerApproved do
    def run_loop(_workspace_path, _issue, _pr, _opts \\ []) do
      {:ok, %{approved_equivalent: true, blocking_findings: [], tests_required: [], residual_risk: ""}}
    end
  end

  defmodule FakeReviewRunnerApprovedStructured do
    def run_loop(_workspace_path, _issue, _pr, _opts \\ []) do
      {:ok,
       %{
         approved_equivalent: true,
         blocking_findings: [
           %{"file" => "lib/example.ex", "line" => 42, "issue" => "Structured finding handled"}
         ],
         tests_required: [
           %{"command" => "mix test", "result" => "passed"}
         ],
         residual_risk: %{"note" => "none"}
       }}
    end
  end

  defmodule FakeReviewRunnerBlocked do
    def run_loop(_workspace_path, _issue, _pr, _opts \\ []), do: {:error, :review_blocked}
  end

  defmodule FakeTrackerUpdateInReview do
    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_state_update_called, issue_id, state_name})

        _ ->
          :ok
      end

      :ok
    end

    def create_comment(issue_id, body) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_comment_called, issue_id, body})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeTrackerRefreshesLinkedPullRequest do
    alias SymphonyElixir.Linear.Issue

    def fetch_issue_states_by_ids([issue_id]) do
      {:ok,
       [
         %Issue{
           id: issue_id,
           identifier: "MT-PREMATURE-REVIEW-REFRESHED",
           branch_name: "aenima611111/linear-generated-branch",
           state: "In Review",
           attachment_urls: ["https://github.example/pull/79"]
         }
       ]}
    end

    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_state_update_called, issue_id, state_name})

        _ ->
          :ok
      end

      :ok
    end

    def create_comment(issue_id, body) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_comment_called, issue_id, body})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeTrackerNoHandoffRefresh do
    def fetch_issue_states_by_ids(issue_ids) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:unexpected_handoff_refresh, issue_ids})

        _ ->
          :ok
      end

      {:ok, []}
    end

    def update_issue_state(_issue_id, _state_name), do: :ok

    def create_comment(issue_id, body) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_comment_called, issue_id, body})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeTrackerUpdateInReviewError do
    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_state_update_called, issue_id, state_name})

        _ ->
          :ok
      end

      {:error, :boom}
    end

    def create_comment(issue_id, body) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_comment_called, issue_id, body})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeTrackerMergedLinkedPrIssues do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(state_names) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:post_merge_fetch_states, state_names})

        _ ->
          :ok
      end

      if "Done" in state_names do
        {:ok, []}
      else
        {:ok,
         [
           %Issue{
             id: "issue-review-merged",
             identifier: "MT-379",
             title: "Merged review issue",
             state: "In Review",
             project_name: "repo",
             description: "Repo: https://github.com/octo/repo",
             attachment_urls: ["https://github.com/octo/repo/pull/200"]
           },
           %Issue{
             id: "issue-progress-merged",
             identifier: "MT-380",
             title: "Merged progress issue",
             state: "In Progress",
             project_name: "repo",
             description: "Repo: https://github.com/octo/repo",
             attachment_urls: ["https://github.com/octo/repo/pull/200"]
           }
         ]}
      end
    end

    def fetch_candidate_issues, do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_state_update_called, issue_id, state_name})

        _ ->
          :ok
      end

      :ok
    end
  end

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
    assert is_integer(completed_state.codex_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 10
    assert completed_state.codex_totals.output_tokens == 5
    assert completed_state.codex_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 200
    assert snapshot_entry.codex_output_tokens == 100
    assert snapshot_entry.codex_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 14
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 0
    assert snapshot_entry.codex_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom",
      pr_number: 987,
      pr_url: "https://example.org/pull/987"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom",
               pr_number: 987,
               pr_url: "https://example.org/pull/987"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "orchestrator moves active and review issues with merged linked PR attachments to Done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupMergedLinkedPr)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerMergedLinkedPrIssues)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :MergedLinkedPrDoneSyncOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    flush_post_merge_test_messages = fn flush ->
      receive do
        {:post_merge_fetch_states, _state_names} -> flush.(flush)
        {:merged_pr_lookup_called, _attachment_urls} -> flush.(flush)
      after
        0 -> :ok
      end
    end

    flush_post_merge_test_messages.(flush_post_merge_test_messages)

    send(pid, :run_poll_cycle)
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:post_merge_fetch_states, state_names}, 200
    assert "Todo" in state_names
    assert "In Progress" in state_names
    assert "In Review" in state_names

    assert_receive {:merged_pr_lookup_called, ["https://github.com/octo/repo/pull/200"]}, 200
    assert_receive {:tracker_state_update_called, "issue-review-merged", "Done"}, 200
    assert_receive {:tracker_state_update_called, "issue-progress-merged", "Done"}, 200

    assert MapSet.member?(state.completed, "issue-review-merged")
    assert MapSet.member?(state.completed, "issue-progress-merged")
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    retry_started_at_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    retry_delay_ms = due_at_ms - retry_started_at_ms
    assert retry_delay_ms >= 9_000
    assert retry_delay_ms <= 10_500
  end

  test "orchestrator blocks stalled workers that are waiting on MCP elicitation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-mcp-elicitation-stall"
    issue = %Issue{id: issue_id, identifier: "MT-MCP", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :McpElicitationBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-MCP",
      issue: issue,
      worker_host: "dm-dev2",
      workspace_path: "/workspaces/MT-MCP",
      session_id: "thread-mcp-turn-mcp",
      last_codex_message: %{
        event: :notification,
        message: %{"method" => "mcpServer/elicitation/request"},
        timestamp: stale_activity_at
      },
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-MCP",
             error: "codex MCP elicitation requires operator input",
             worker_host: "dm-dev2",
             workspace_path: "/workspaces/MT-MCP"
           } = state.blocked[issue_id]

    assert %{blocked: [%{identifier: "MT-MCP", error: "codex MCP elicitation requires operator input"}]} =
             Orchestrator.snapshot(orchestrator_name, 5_000)
  end

  test "orchestrator blocks repeated identical test failure fingerprints" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      same_test_failure_fingerprint_limit: 2
    )

    issue_id = "issue-repeated-test-fingerprint"
    orchestrator_name = Module.concat(__MODULE__, :RepeatedTestFingerprintOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-REPEAT-TEST",
      issue: %Issue{id: issue_id, identifier: "MT-REPEAT-TEST", state: "In Progress"},
      session_id: "thread-repeated-test-fingerprint",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    failed_command_update = fn ->
      %{
        event: :notification,
        payload: %{
          "method" => "codex/event/exec_command_end",
          "params" => %{
            "msg" => %{
              "command" => "mix test test/symphony_elixir/orchestrator_status_test.exs",
              "exit_code" => 1
            }
          }
        },
        timestamp: DateTime.utc_now()
      }
    end

    send(pid, {:codex_worker_update, issue_id, failed_command_update.()})
    Process.sleep(50)

    state_after_first = :sys.get_state(pid)
    assert Map.has_key?(state_after_first.running, issue_id)
    refute Map.has_key?(state_after_first.blocked, issue_id)

    send(pid, {:codex_worker_update, issue_id, failed_command_update.()})
    Process.sleep(50)

    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             identifier: "MT-REPEAT-TEST",
             error: "repeated test failure fingerprint reached limit 2"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks repeated identical review fingerprints" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      same_review_fingerprint_limit: 2
    )

    issue_id = "issue-repeated-review-fingerprint"
    orchestrator_name = Module.concat(__MODULE__, :RepeatedReviewFingerprintOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-REPEAT-REVIEW",
      issue: %Issue{id: issue_id, identifier: "MT-REPEAT-REVIEW", state: "In Progress"},
      session_id: "thread-repeated-review-fingerprint",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    review_update = fn ->
      %{
        event: :notification,
        payload: %{
          "method" => "codex/event/agent_message_delta",
          "params" => %{
            "msg" => %{
              "delta" => "Request changes: please fix the missing retry test coverage"
            }
          }
        },
        timestamp: DateTime.utc_now()
      }
    end

    send(pid, {:codex_worker_update, issue_id, review_update.()})
    Process.sleep(50)

    state_after_first = :sys.get_state(pid)
    assert Map.has_key?(state_after_first.running, issue_id)
    refute Map.has_key?(state_after_first.blocked, issue_id)

    send(pid, {:codex_worker_update, issue_id, review_update.()})
    Process.sleep(50)

    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             identifier: "MT-REPEAT-REVIEW",
             error: "repeated review fingerprint reached limit 2"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks failed workers after app-server reports input required" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-input-required"
    issue = %Issue{id: issue_id, identifier: "MT-INPUT", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :InputRequiredBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    started_at = DateTime.utc_now()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-INPUT",
      issue: issue,
      session_id: "thread-input-turn-input",
      last_codex_message: %{
        event: :turn_input_required,
        message: %{"method" => "mcpServer/elicitation/request"},
        timestamp: started_at
      },
      last_codex_timestamp: started_at,
      last_codex_event: :turn_input_required,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :input_required}})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-INPUT",
             error: "codex turn requires operator input"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks normal worker exits after input required completion" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    issue_id = "issue-input-required-normal"
    orchestrator_name = Module.concat(__MODULE__, :InputRequiredNormalBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-INPUT-NORMAL",
      issue: %Issue{id: issue_id, identifier: "MT-INPUT-NORMAL", state: "In Progress"},
      session_id: "thread-input-normal",
      completion: %{outcome: :input_required},
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(650)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             identifier: "MT-INPUT-NORMAL",
             error: "codex turn requires operator input"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks normal worker exits when branch has no discoverable PR" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_publisher = Application.get_env(:symphony_elixir, :github_pr_publisher)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_publisher) do
        Application.delete_env(:symphony_elixir, :github_pr_publisher)
      else
        Application.put_env(:symphony_elixir, :github_pr_publisher, previous_publisher)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupNone)
    Application.put_env(:symphony_elixir, :github_pr_publisher, FakeGitHubPrPublisherError)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerNoHandoffRefresh)

    issue_id = "issue-normal-no-pr"
    orchestrator_name = Module.concat(__MODULE__, :NormalNoPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-NO-PR",
      branch_name: "feature/no-pr",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-no-pr",
      session_id: "thread-no-pr",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(650)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-NO-PR",
             error: "no GitHub PR found for branch feature/no-pr or linked PR attachments; agent-owned PR is required before In Review handoff"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks unexpected PR lookup results without refreshing issue attachments" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupUnexpected)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerNoHandoffRefresh)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-unexpected-pr-lookup"
    orchestrator_name = Module.concat(__MODULE__, :NormalUnexpectedPrLookupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-UNEXPECTED-PR-LOOKUP",
      branch_name: "feature/unexpected-pr-lookup",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-unexpected-pr-lookup",
      session_id: "thread-unexpected-pr-lookup",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:tracker_comment_called, ^issue_id, comment_body}
    refute_receive {:unexpected_handoff_refresh, _issue_ids}, 100
    state = :sys.get_state(pid)

    assert comment_body =~ "Symphony blocked MT-UNEXPECTED-PR-LOOKUP"

    assert %{
             identifier: "MT-UNEXPECTED-PR-LOOKUP",
             error: "GitHub PR lookup returned unexpected result for branch feature/unexpected-pr-lookup"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks normal worker exits when workspace exists but branch is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    issue_id = "issue-normal-missing-branch"
    orchestrator_name = Module.concat(__MODULE__, :NormalMissingBranchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-MISSING-BRANCH",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-missing-branch",
      session_id: "thread-missing-branch",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-MISSING-BRANCH",
             error: "no branch name available for GitHub PR lookup"
           } = state.blocked[issue_id]
  end

  test "orchestrator moves to In Review and does not retry on normal exit with discoverable PR" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-pr-found"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrFoundOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PR-FOUND",
      branch_name: "feature/pr-found",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-pr-found",
      session_id: "thread-pr-found",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "Merge judgment: ready for human final merge decision"
    assert comment =~ "The runtime will not approve on GitHub and will not merge automatically."

    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator refreshes issue attachments before blocking normal handoff without PR" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupLinkedPrFallback)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerRefreshesLinkedPullRequest)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-refresh-linked-pr"
    orchestrator_name = Module.concat(__MODULE__, :NormalRefreshLinkedPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-NORMAL-REFRESH-LINKED-PR",
      branch_name: "aenima611111/linear-generated-branch",
      state: "In Progress",
      attachment_urls: []
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-normal-refresh-linked-pr",
      session_id: "thread-normal-refresh-linked-pr",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "source: linked GitHub PR attachment"

    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "orchestrator accepts linked PR attachment fallback when Linear branch lookup misses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupLinkedPrFallback)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-linked-pr-found"
    orchestrator_name = Module.concat(__MODULE__, :NormalLinkedPrFoundOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LINKED-PR",
      branch_name: "feature/linear-branch",
      attachment_urls: ["https://github.example/pull/79"],
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-linked-pr-found",
      session_id: "thread-linked-pr-found",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "PR: https://github.example/pull/79"
    assert comment =~ "source: linked GitHub PR attachment"
    assert comment =~ "expected Linear branch: feature/linear-branch"
    assert comment =~ "actual PR branch: feature/actual-pr"

    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator comments on structured approved review verdicts" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApprovedStructured)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-pr-structured-verdict"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrStructuredVerdictOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-STRUCTURED-VERDICT",
      branch_name: "feature/structured-verdict",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-structured-verdict",
      session_id: "thread-structured-verdict",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "lib/example.ex:42 - Structured finding handled"
    assert comment =~ "mix test"
    assert comment =~ "none"

    assert MapSet.member?(state.completed, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator blocks review handoff when reviewer does not approve the PR" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerBlocked)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-pr-review-blocked"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrReviewBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-REVIEW-BLOCKED",
      branch_name: "feature/review-blocked",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-review-blocked",
      session_id: "thread-review-blocked",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 100
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "review loop did not approve PR"

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-REVIEW-BLOCKED",
             error: "review loop did not approve PR before In Review handoff: :review_blocked"
           } = state.blocked[issue_id]
  end

  test "orchestrator returns premature In Review issues to Rework when reviewer does not approve" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_review_state: "In Review"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerBlocked)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-premature-review-blocked"
    orchestrator_name = Module.concat(__MODULE__, :PrematureReviewBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PREMATURE-REVIEW",
      branch_name: "feature/premature-review",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: agent_pid,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-premature-review",
      session_id: "thread-premature-review",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    review_issue = %{issue | state: "In Review"}
    :sys.replace_state(pid, &Orchestrator.reconcile_issue_states_for_test([review_issue], &1))
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "Rework"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "review loop did not approve PR"

    refute Process.alive?(agent_pid)
    refute MapSet.member?(state.completed, issue_id)

    assert %{
             identifier: "MT-PREMATURE-REVIEW",
             issue: %Issue{state: "Rework"},
             error: "review loop did not approve PR before In Review handoff: :review_blocked"
           } = state.blocked[issue_id]
  end

  test "orchestrator comments before accepting premature In Review issues when reviewer approves" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_review_state: "In Review"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-premature-review-approved"
    orchestrator_name = Module.concat(__MODULE__, :PrematureReviewApprovedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PREMATURE-REVIEW-APPROVED",
      branch_name: "feature/premature-review-approved",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: agent_pid,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-premature-review-approved",
      session_id: "thread-premature-review-approved",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    review_issue = %{issue | state: "In Review"}
    :sys.replace_state(pid, &Orchestrator.reconcile_issue_states_for_test([review_issue], &1))
    state = :sys.get_state(pid)

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "Merge judgment: ready for human final merge decision"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200

    refute Process.alive?(agent_pid)
    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "orchestrator refreshes In Review issue attachments before blocking handoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_review_state: "In Review"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_comment_recipient,
          previous_tracker_comment_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupLinkedPrFallback)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerRefreshesLinkedPullRequest)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-premature-review-refresh"
    orchestrator_name = Module.concat(__MODULE__, :PrematureReviewRefreshOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PREMATURE-REVIEW-REFRESHED",
      branch_name: "aenima611111/linear-generated-branch",
      state: "In Progress",
      attachment_urls: []
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: agent_pid,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-premature-review-refreshed",
      session_id: "thread-premature-review-refreshed",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    stale_review_issue = %{issue | state: "In Review", attachment_urls: []}
    :sys.replace_state(pid, &Orchestrator.reconcile_issue_states_for_test([stale_review_issue], &1))
    state = :sys.get_state(pid)

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "source: linked GitHub PR attachment"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200

    refute Process.alive?(agent_pid)
    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "orchestrator moves to configured review state when tracker state is customized" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil, tracker_review_state: "Review")

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())

    issue_id = "issue-normal-pr-found-custom-state"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrFoundCustomStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PR-FOUND-CUSTOM",
      branch_name: "feature/pr-found",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-pr-found-custom",
      session_id: "thread-pr-found-custom",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "Review"}, 200

    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator blocks normal exits when PR state transition to In Review fails" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReviewError)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())

    issue_id = "issue-normal-pr-state-failed"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrFoundTransitionFailedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PR-FAILED",
      branch_name: "feature/pr-found-failed",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-pr-found-failed",
      session_id: "thread-pr-found-failed",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-PR-FAILED",
             error: "failed to move issue to In Review after PR discovery: :boom"
           } = state.blocked[issue_id]
  end

  test "orchestrator blocks normal exits when PR lookup fails" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupError)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerNoHandoffRefresh)

    issue_id = "issue-normal-pr-error"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrErrorOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PR-ERROR",
      branch_name: "feature/pr-error",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-pr-error",
      session_id: "thread-pr-error",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(650)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-PR-ERROR",
             error: "GitHub PR lookup failed for branch feature/pr-error: :missing_auth"
           } = state.blocked[issue_id]
  end

  test "orchestrator schedules max-turn active issue exits for continuation" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-max-turn-block"
    issue = %Issue{id: issue_id, identifier: "MT-MAX", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :MaxTurnBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-MAX",
      issue: issue,
      session_id: "thread-max-turns",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), {:max_turns_reached_active_issue, issue_id}})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             identifier: "MT-MAX",
             delay_type: :continuation,
             continuation_count: 1,
             error: error
           } = state.retry_attempts[issue_id]

    assert is_integer(state.retry_attempts[issue_id].due_at_ms)
    assert error =~ "agent.max_turns reached while Linear issue stayed active; scheduling continuation"
    assert error =~ ":missing_branch_or_workspace"
    assert MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
    refute_receive {:memory_tracker_comment, ^issue_id, _comment}, 50
  end

  test "orchestrator blocks max-turn active issue exits after continuation limit" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      max_continuations: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-max-turn-continuation-limit"
    issue = %Issue{id: issue_id, identifier: "MT-MAX-LIMIT", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :MaxTurnContinuationLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-MAX-LIMIT",
      issue: issue,
      session_id: "thread-max-turns-limit",
      continuation_count: 1,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), {:max_turns_reached_active_issue, issue_id}})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.completed, issue_id)

    assert %{
             identifier: "MT-MAX-LIMIT",
             error: error
           } = state.blocked[issue_id]

    assert error =~ "agent.max_turns continuation limit reached (1); blocking active issue"
    assert error =~ ":missing_branch_or_workspace"

    assert_receive {:memory_tracker_comment, ^issue_id, comment}, 250
    assert comment =~ "Symphony blocked MT-MAX-LIMIT."
    assert comment =~ "agent.max_turns continuation limit reached (1); blocking active issue"
  end

  test "orchestrator blocks dirty workspace exits instead of retrying" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-dirty-workspace-block"
    issue = %Issue{id: issue_id, identifier: "MT-DIRTY-BLOCK", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :DirtyWorkspaceBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-DIRTY-BLOCK",
      issue: issue,
      workspace_path: "/tmp/mt-dirty-block",
      session_id: "thread-dirty-workspace",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:DOWN, ref, :process, self(), {:dirty_workspace, "/tmp/mt-dirty-block", "?? docs/operations/LAB-269-smoke.md\n"}}
    )

    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             identifier: "MT-DIRTY-BLOCK",
             error: "dirty workspace detected at /tmp/mt-dirty-block: ?? docs/operations/LAB-269-smoke.md"
           } = state.blocked[issue_id]

    assert_receive {:memory_tracker_comment, ^issue_id, comment}
    assert comment =~ "Symphony blocked MT-DIRTY-BLOCK"
    assert comment =~ "dirty workspace detected at /tmp/mt-dirty-block"
    assert comment =~ "docs/operations/LAB-269-smoke.md"
  end

  test "orchestrator moves max-turn active issue exits to review when a PR is discoverable" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_review_runner) do
        Application.delete_env(:symphony_elixir, :review_runner)
      else
        Application.put_env(:symphony_elixir, :review_runner, previous_review_runner)
      end

      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(
          :symphony_elixir,
          :tracker_state_update_recipient,
          previous_tracker_state_update_recipient
        )
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupFound)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())

    issue_id = "issue-max-turn-pr-found"
    orchestrator_name = Module.concat(__MODULE__, :MaxTurnPrFoundOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-MAX-PR",
      branch_name: "feature/max-turn-pr-found",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-max-pr-found",
      session_id: "thread-max-turn-pr-found",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), {:max_turns_reached_active_issue, issue_id}})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200

    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator snapshot includes branch_name for running entries" do
    issue_id = "issue-branch-snapshot-running"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BR-RUN",
      branch_name: "feature/branch-snapshot-running",
      title: "Running snapshot branch name",
      description: "Expose branch name in running snapshot",
      state: "In Progress",
      url: "https://example.org/issues/MT-BR-RUN"
    }

    orchestrator_name = Module.concat(__MODULE__, :BranchSnapshotRunningOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.branch_name == "feature/branch-snapshot-running"
  end

  test "orchestrator snapshot includes branch_name for blocked entries" do
    issue_id = "issue-branch-snapshot-blocked"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BR-BLK",
      branch_name: "feature/branch-snapshot-blocked",
      title: "Blocked snapshot branch name",
      description: "Expose branch name in blocked snapshot",
      state: "In Progress",
      url: "https://example.org/issues/MT-BR-BLK"
    }

    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)
    previous_tracker_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_tracker_comment_recipient)
      end
    end)

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :BranchSnapshotBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-branch-block",
      turn_count: 0,
      last_codex_message: %{
        event: :turn_input_required,
        message: %{method: "thread/inputRequired"},
        timestamp: DateTime.utc_now()
      },
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_event: :turn_input_required,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    assert_receive {:tracker_comment_called, ^issue_id, comment}
    assert comment =~ "Symphony blocked MT-BR-BLK"
    assert comment =~ "codex turn requires operator input"

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert %{blocked: [snapshot_entry]} = snapshot
    assert snapshot_entry.branch_name == "feature/branch-snapshot-blocked"
  end

  test "orchestrator snapshot supports blocked entries without issue payload" do
    issue_id = "issue-branch-missing-issue-blocked"

    orchestrator_name = Module.concat(__MODULE__, :BranchSnapshotBlockedNoIssueOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    blocked_entry = %{
      identifier: "MT-BR-NO",
      error: "manual regression",
      worker_host: "dm-dev2",
      workspace_path: "/workspaces/MT-BR-NO",
      session_id: "thread-no-issue",
      blocked_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: %{
        event: :notification,
        message: %{method: "thread/inputRequired"},
        timestamp: DateTime.utc_now()
      },
      last_codex_event: :turn_input_required
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert %{blocked: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.identifier == "MT-BR-NO"
    assert snapshot_entry.branch_name == nil
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders linear project link in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "│ Project:"
    assert rendered =~ "https://linear.app/project/project/issues"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard prefers the bound server port and normalizes wildcard hosts" do
    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 0, 43_123) ==
             "http://127.0.0.1:43123/"

    assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
             "http://[::1]:4000/"
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds a spacer line before backoff queue when no agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             codex_app_server_pid: "4242",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "turn_completed",
             last_codex_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Backoff queue/s
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 200

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 200
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert StatusDashboard.rolling_tps([], 10_000, 0) == 0.0

    assert StatusDashboard.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert StatusDashboard.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      StatusDashboard.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      StatusDashboard.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      StatusDashboard.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      StatusDashboard.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert StatusDashboard.format_timestamp_for_test(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens)

    graph_next_second =
      StatusDashboard.tps_graph_for_test(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-233",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: %{
          event: :notification,
          message: %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }
        }
      })

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-898",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: payload
      })

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 123,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        terminal_columns
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full codex app-server event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        StatusDashboard.humanize_codex_message(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested codex payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert StatusDashboard.humanize_codex_message(wrapped) =~ "turn completed"
    assert StatusDashboard.humanize_codex_message(wrapped) =~ "in 10"
  end

  test "status dashboard uses shell command line as exec command status text" do
    message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from codex" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from codex" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert StatusDashboard.humanize_codex_message(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert StatusDashboard.humanize_codex_message(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert StatusDashboard.humanize_codex_message(fallback_reasoning) == "reasoning update"
  end

  test "application stop renders offline status" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.Application.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end
end
