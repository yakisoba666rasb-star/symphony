defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  defmodule FakeGitHubPrLookupNone do
    def lookup_workspace_head(_workspace_path, _branch_name), do: {:ok, nil}
  end

  defmodule FakeGitHubIssueIntake do
    def sync_open_issues_to_linear(settings, adapter, attempts) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_issue_intake_sync, settings.github_intake.state, adapter, attempts})

        _ ->
          :ok
      end

      {:ok, %{created: 1, skipped: 2, errors: 0}, Map.put(attempts, "https://github.com/octo/repo/issues/1", %{reason: :down, attempts: 1, last_attempt_ms: 1})}
    end
  end

  defmodule FakeGitHubIssueIntakeCrash do
    def sync_open_issues_to_linear(_settings, _adapter, _attempts) do
      raise "github intake failed"
    end
  end

  defmodule FakeLinearIntakeAdapter do
  end

  defmodule FakeLinearIntakeTracker do
    def adapter, do: FakeLinearIntakeAdapter
  end

  defmodule FakeLandingTracker do
    def fetch_issues_by_states(states) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:landing_fetch_states, states})

        _ ->
          :ok
      end

      {:ok, Application.get_env(:symphony_elixir, :landing_planner_issues, [])}
    end

    def create_comment(issue_id, body) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:landing_comment, issue_id, body})

        _ ->
          :ok
      end

      :ok
    end

    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:landing_state_update, issue_id, state_name})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeLandingWorker do
    def execute(settings, _tracker, queue) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:landing_worker_execute, settings.landing.execute_enabled, length(queue)})

        _ ->
          :ok
      end

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
  end

  defmodule FakeLandingPrLookup do
    def lookup_open_issue_pull_request(repo, issue_identifier, _issue_url, branch_name, _attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:landing_pr_lookup, repo, issue_identifier, branch_name})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 600,
         "url" => "https://github.com/octo/repo/pull/600",
         "headRefName" => branch_name,
         "isDraft" => false,
         "mergeStateStatus" => "CLEAN",
         "state" => "OPEN"
       }}
    end
  end

  defmodule FakeGitHubPrLookupFound do
    def lookup_workspace_head(_workspace_path, _branch_name), do: {:ok, %{"number" => 123, "url" => "https://example.org/pull/123"}}
  end

  defmodule FakeGitHubPrLookupOpenIssuePr do
    def lookup_open_issue_pull_request(repo, issue_identifier, issue_url, branch_name, attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(
            recipient,
            {:open_issue_pr_lookup_called, repo, issue_identifier, issue_url, branch_name, attachment_urls}
          )

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 83,
         "url" => "https://github.com/octo/repo/pull/83",
         "headRefName" => "LAB-391-retry-policy",
         "isDraft" => false,
         "mergeStateStatus" => "CLEAN",
         "state" => "OPEN",
         "__symphonyLookupSource" => "open_issue_pull_request"
       }}
    end
  end

  defmodule FakeGitHubPrLookupDirtyOpenIssuePr do
    def lookup_open_issue_pull_request(repo, issue_identifier, issue_url, branch_name, attachment_urls) do
      merge_state = Application.get_env(:symphony_elixir, :fake_open_issue_pr_merge_state, "DIRTY")

      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(
            recipient,
            {:open_issue_pr_lookup_called, repo, issue_identifier, issue_url, branch_name, attachment_urls}
          )

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 200,
         "url" => "https://github.com/octo/repo/pull/200",
         "headRefName" => branch_name,
         "isDraft" => false,
         "mergeStateStatus" => merge_state,
         "state" => "OPEN",
         "__symphonyLookupSource" => "open_issue_pull_request"
       }}
    end
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

    def lookup_merged_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_issue_pr_lookup_called, issue_identifier, issue_url, branch_name})

        _ ->
          :ok
      end

      if issue_identifier == "MT-381" and
           issue_url == "https://linear.app/example/issue/MT-381/body-linked-merged-pr" do
        {:ok,
         %{
           "number" => 201,
           "url" => "https://github.com/octo/repo/pull/201",
           "headRefName" => "lab-381-body-linked",
           "state" => "MERGED",
           "mergedAt" => "2026-06-09T03:42:42Z"
         }}
      else
        if issue_identifier == "MT-382" and
             issue_url == "https://linear.app/example/issue/MT-382/no-pr-evidence" do
          {:ok,
           %{
             "number" => 202,
             "url" => "https://github.com/octo/repo/pull/202",
             "headRefName" => "lab-382-identifier-only",
             "state" => "MERGED",
             "mergedAt" => "2026-06-09T04:42:42Z"
           }}
        else
          {:ok, nil}
        end
      end
    end
  end

  defmodule FakeGitHubPrLookupAnyMergedLinkedPr do
    def lookup_merged_linked_pull_request("octo/repo", [url | _]) do
      {:ok,
       %{
         "number" => 200,
         "url" => url,
         "headRefName" => "lab-done-sync",
         "state" => "MERGED",
         "mergedAt" => "2026-06-09T01:42:42Z"
       }}
    end

    def lookup_merged_issue_pull_request(_repo, _issue_identifier, _issue_url, _branch_name), do: {:ok, nil}
  end

  defmodule FakeGitHubPrLookupImplementationMergedPr do
    def lookup_merged_linked_pull_request("octo/repo", attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_pr_lookup_called, attachment_urls})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 87,
         "url" => "https://github.com/octo/repo/pull/87",
         "headRefName" => "docs-routing-contract",
         "state" => "MERGED",
         "mergedAt" => "2026-06-09T01:42:42Z",
         "__symphonyLookupSource" => "merged_linked_pull_request"
       }}
    end

    def lookup_merged_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_issue_pr_lookup_called, issue_identifier, issue_url, branch_name})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 88,
         "url" => "https://github.com/octo/repo/pull/88",
         "headRefName" => branch_name,
         "state" => "MERGED",
         "mergedAt" => "2026-06-09T03:42:42Z",
         "__symphonyLookupSource" => "merged_issue_pull_request",
         "__symphonyMatchedBranch" => branch_name
       }}
    end
  end

  defmodule FakeGitHubPrLookupOpenImplementationPr do
    def lookup_merged_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_issue_pr_lookup_called, issue_identifier, issue_url, branch_name})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def lookup_open_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name, attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:open_issue_pr_lookup_called, issue_identifier, issue_url, branch_name, attachment_urls})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 88,
         "url" => "https://github.com/octo/repo/pull/88",
         "headRefName" => branch_name,
         "state" => "OPEN",
         "isDraft" => false,
         "__symphonyLookupSource" => "open_issue_pull_request"
       }}
    end

    def lookup_merged_linked_pull_request("octo/repo", attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_pr_lookup_called, attachment_urls})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 87,
         "url" => "https://github.com/octo/repo/pull/87",
         "headRefName" => "docs-routing-contract",
         "state" => "MERGED",
         "mergedAt" => "2026-06-09T01:42:42Z",
         "__symphonyLookupSource" => "merged_linked_pull_request"
       }}
    end
  end

  defmodule FakeGitHubPrLookupMismatchedMergedLinkedPr do
    def lookup_merged_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_issue_pr_lookup_called, issue_identifier, issue_url, branch_name})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def lookup_open_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name, attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:open_issue_pr_lookup_called, issue_identifier, issue_url, branch_name, attachment_urls})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def lookup_merged_linked_pull_request("octo/repo", attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_pr_lookup_called, attachment_urls})

        _ ->
          :ok
      end

      {:ok,
       %{
         "number" => 87,
         "url" => "https://github.com/octo/repo/pull/87",
         "headRefName" => "docs-routing-contract",
         "state" => "MERGED",
         "mergedAt" => "2026-06-09T01:42:42Z",
         "__symphonyLookupSource" => "merged_linked_pull_request"
       }}
    end
  end

  defmodule FakeGitHubPrLookupAmbiguousLinkedPr do
    def lookup_merged_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_issue_pr_lookup_called, issue_identifier, issue_url, branch_name})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def lookup_open_issue_pull_request("octo/repo", issue_identifier, issue_url, branch_name, attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:open_issue_pr_lookup_called, issue_identifier, issue_url, branch_name, attachment_urls})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def lookup_merged_linked_pull_request("octo/repo", attachment_urls) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:merged_pr_lookup_called, attachment_urls})

        _ ->
          :ok
      end

      {:error, {:ambiguous_linked_pull_requests, attachment_urls}}
    end
  end

  defmodule FakeGitHubIssueCloser do
    def closed_at(repo, issue_url) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_issue_closed_at_called, repo, issue_url})

        _ ->
          :ok
      end

      {:ok, nil}
    end

    def close_if_open(repo, issue_url, comment) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_issue_close_called, repo, issue_url, comment})

        _ ->
          :ok
      end

      {:ok, :closed}
    end
  end

  defmodule FakeGitHubIssueAlreadyClosed do
    def closed_at(repo, issue_url) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_issue_closed_at_called, repo, issue_url})

        _ ->
          :ok
      end

      {:ok, "2026-06-18T13:34:00Z"}
    end

    def close_if_open(repo, issue_url, comment) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_issue_close_called, repo, issue_url, comment})

        _ ->
          :ok
      end

      {:ok, :already_closed}
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

  defmodule FakeReviewRunnerSlowApproved do
    def run_loop(_workspace_path, _issue, _pr, _opts \\ []) do
      case Application.get_env(:symphony_elixir, :review_runner_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, :slow_review_started)

        _ ->
          :ok
      end

      Process.sleep(750)
      {:ok, %{approved_equivalent: true, blocking_findings: [], tests_required: [], residual_risk: ""}}
    end
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

  defmodule FakeGitHubReviewChangesRequested do
    def view("https://github.com/acme/repo/pull/77") do
      {:ok,
       %{
         decision: "CHANGES_REQUESTED",
         state: "OPEN",
         latest_changes_requested_review_id: "review-77",
         changes_requested_body: "Please fix the failing retry path."
       }}
    end
  end

  defmodule FakeGitHubReviewApproved do
    def view("https://github.com/acme/repo/pull/77") do
      {:ok,
       %{
         decision: "APPROVED",
         state: "OPEN",
         latest_changes_requested_review_id: nil,
         changes_requested_body: ""
       }}
    end
  end

  defmodule FakeGitHubReviewCountingApproved do
    def view(url) when is_binary(url) do
      case Application.get_env(:symphony_elixir, :github_review_status_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:github_review_status_view, url})

        _ ->
          :ok
      end

      {:ok,
       %{
         decision: "APPROVED",
         state: "OPEN",
         latest_changes_requested_review_id: nil,
         changes_requested_body: ""
       }}
    end
  end

  defmodule FakeAgentRunnerRecords do
    def run(issue, _recipient, opts) do
      case Application.get_env(:symphony_elixir, :agent_runner_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:agent_runner_called, issue, opts})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeAgentRunnerRecordsSlow do
    def run(issue, recipient, opts) do
      FakeAgentRunnerRecords.run(issue, recipient, opts)
      Process.sleep(2_000)
      :ok
    end
  end

  defmodule FakeAgentRunnerRecordsBlocking do
    def run(issue, recipient, opts) do
      FakeAgentRunnerRecords.run(issue, recipient, opts)

      case Application.get_env(:symphony_elixir, :agent_runner_blocking_recipient) do
        owner when is_pid(owner) ->
          ref = make_ref()
          send(owner, {:agent_runner_blocking, self(), issue.id, ref})

          receive do
            {:release_agent_runner, ^ref} -> :ok
          after
            5_000 -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defmodule FakeTrackerActiveOpenPrReconcile do
    def fetch_issues_by_states(states) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:active_open_pr_reconcile_fetch_called, states})

        _ ->
          :ok
      end

      {:ok, Application.get_env(:symphony_elixir, :active_open_pr_reconcile_issues, [])}
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

  defmodule FakeTrackerCommentError do
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

      {:error, :comment_transport_closed}
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
           },
           %Issue{
             id: "issue-body-linked-merged",
             identifier: "MT-381",
             title: "Merged issue without PR attachment",
             state: "In Progress",
             url: "https://linear.app/example/issue/MT-381/body-linked-merged-pr",
             branch_name: "lab-381-body-linked",
             project_name: "repo",
             description: "Repo: https://github.com/octo/repo",
             attachment_urls: ["https://github.com/octo/repo/issues/381"]
           },
           %Issue{
             id: "issue-identifier-url-only",
             identifier: "MT-382",
             title: "Issue without PR or branch evidence",
             state: "In Progress",
             url: "https://linear.app/example/issue/MT-382/no-pr-evidence",
             project_name: "repo",
             description: "Repo: https://github.com/octo/repo",
             attachment_urls: []
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

    def remove_issue_labels(issue_id, labels) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_remove_labels_called, issue_id, labels})

        _ ->
          :ok
      end

      :ok
    end
  end

  defmodule FakeTrackerAlreadyDoneSourceIssue do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(state_names) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:post_merge_fetch_states, state_names})

        _ ->
          :ok
      end

      if "Done" in state_names do
        {:ok,
         [
           %Issue{
             id: "issue-already-done-source",
             identifier: "MT-381",
             title: "Already Done issue with stale source GitHub issue",
             state: "Done",
             url: "https://linear.app/example/issue/MT-381/body-linked-merged-pr",
             branch_name: "lab-381-body-linked",
             project_name: "repo",
             description: "Repo: https://github.com/octo/repo",
             attachment_urls: ["https://github.com/octo/repo/issues/381"]
           }
         ]}
      else
        {:ok, []}
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

  defmodule FakeTrackerDoneSyncImplementationIssue do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(state_names) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:post_merge_fetch_states, state_names})

        _ ->
          :ok
      end

      {:ok,
       [
         %Issue{
           id: "issue-lab-396",
           identifier: "LAB-396",
           title: "Implementation PR should satisfy Done sync",
           state: "In Progress",
           url: "https://linear.app/example/issue/LAB-396/implementation",
           branch_name: "lab-396-implementation",
           project_name: "repo",
           description: "Repo: https://github.com/octo/repo",
           attachment_urls: ["https://github.com/octo/repo/pull/87"]
         }
       ]}
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

  defmodule FakeTrackerDoneSyncAmbiguousLinkedIssue do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(state_names) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:post_merge_fetch_states, state_names})

        _ ->
          :ok
      end

      {:ok,
       [
         %Issue{
           id: "issue-lab-467",
           identifier: "LAB-467",
           title: "Meta issue with sample merged PR attachments",
           state: "In Progress",
           url: "https://linear.app/example/issue/LAB-467/meta",
           branch_name: "lab-467-implementation",
           project_name: "repo",
           description: "Repo: https://github.com/octo/repo",
           attachment_urls: [
             "https://github.com/octo/repo/pull/166",
             "https://github.com/octo/repo/pull/154"
           ]
         }
       ]}
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

  defmodule FakeTrackerDoneSyncOpenImplementationIssue do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(state_names) do
      case Application.get_env(:symphony_elixir, :tracker_comment_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:post_merge_fetch_states, state_names})

        _ ->
          :ok
      end

      {:ok,
       [
         %Issue{
           id: "issue-lab-396-open",
           identifier: "LAB-396",
           title: "Open implementation PR should block docs Done sync",
           state: "In Progress",
           url: "https://linear.app/example/issue/LAB-396/implementation",
           branch_name: "lab-396-implementation",
           project_name: "repo",
           description: "Repo: https://github.com/octo/repo",
           attachment_urls: ["https://github.com/octo/repo/pull/87"]
         }
       ]}
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

  defmodule FakeTrackerDoneSyncUpdateError do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(_state_names) do
      attachment_url =
        Application.get_env(
          :symphony_elixir,
          :done_sync_attachment_url,
          "https://github.com/octo/repo/pull/200"
        )

      {:ok,
       [
         %Issue{
           id: "issue-done-sync-update-error",
           identifier: "MT-DONE-SYNC-ERROR",
           title: "Merged issue update failure",
           state: "In Progress",
           project_name: "repo",
           description: "Repo: https://github.com/octo/repo",
           attachment_urls: [attachment_url]
         }
       ]}
    end

    def fetch_candidate_issues, do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :tracker_state_update_recipient) do
        recipient when is_pid(recipient) ->
          send(recipient, {:tracker_state_update_called, issue_id, state_name})

        _ ->
          :ok
      end

      {:error, :done_update_failed}
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

  test "GitHub issue intake runs asynchronously and respects interval throttle" do
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
    previous_tracker = Application.get_env(:symphony_elixir, :tracker_module)
    previous_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_github_issue),
        do: Application.delete_env(:symphony_elixir, :github_issue),
        else: Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)

      if is_nil(previous_tracker),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker)

      if is_nil(previous_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_recipient)
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_team_key: "LAB",
      tracker_all_projects: true,
      repository_default: "octo/repo",
      repository_project_routes: %{"octo/repo" => ["Symphony"]},
      github_intake_enabled: true,
      github_intake_state: "Backlog",
      github_intake_interval_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueIntake)
    Application.put_env(:symphony_elixir, :tracker_module, FakeLinearIntakeTracker)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    state = Orchestrator.sync_github_issue_intake_for_test(%Orchestrator.State{})
    assert is_integer(state.last_github_intake_sync_ms)
    assert %Task{ref: ref} = state.github_intake_task
    assert state.github_intake_attempts == %{}

    assert_receive {:github_issue_intake_sync, "Backlog", FakeLinearIntakeAdapter, %{}}

    _state = Orchestrator.sync_github_issue_intake_for_test(state)
    refute_received {:github_issue_intake_sync, "Backlog", FakeLinearIntakeAdapter, _attempts}

    assert_receive {^ref, {result, attempts}}
    assert {:ok, %{created: 1, skipped: 2, errors: 0}} = result

    {:noreply, state} = Orchestrator.handle_info({ref, {result, attempts}}, state)

    assert state.github_intake_task == nil

    assert state.github_intake_attempts == %{
             "https://github.com/octo/repo/issues/1" => %{reason: :down, attempts: 1, last_attempt_ms: 1}
           }

    due_state = %{state | last_github_intake_sync_ms: System.monotonic_time(:millisecond) - 1_001}
    expected_attempts = state.github_intake_attempts
    _state = Orchestrator.sync_github_issue_intake_for_test(due_state)
    assert_receive {:github_issue_intake_sync, "Backlog", FakeLinearIntakeAdapter, ^expected_attempts}
  end

  test "GitHub issue intake warns while single-flight task remains overdue" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_team_key: "LAB",
      tracker_all_projects: true,
      repository_default: "octo/repo",
      repository_project_routes: %{"octo/repo" => ["Symphony"]},
      github_intake_enabled: true,
      github_intake_state: "Backlog",
      github_intake_interval_ms: 1_000
    )

    task = %Task{pid: self(), ref: make_ref(), owner: self(), mfa: {:erlang, :apply, 2}}

    state = %Orchestrator.State{
      github_intake_task: task,
      last_github_intake_sync_ms: System.monotonic_time(:millisecond) - 1_001
    }

    log =
      capture_log(fn ->
        assert ^state = Orchestrator.sync_github_issue_intake_for_test(state)
      end)

    assert log =~ "GitHub issue intake sync task still running"
  end

  test "GitHub issue intake task crash clears state and preserves interval throttle" do
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
    previous_tracker = Application.get_env(:symphony_elixir, :tracker_module)
    previous_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_github_issue),
        do: Application.delete_env(:symphony_elixir, :github_issue),
        else: Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)

      if is_nil(previous_tracker),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker)

      if is_nil(previous_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_recipient)
    end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_team_key: "LAB",
      tracker_all_projects: true,
      repository_default: "octo/repo",
      repository_project_routes: %{"octo/repo" => ["Symphony"]},
      github_intake_enabled: true,
      github_intake_state: "Backlog",
      github_intake_interval_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueIntakeCrash)
    Application.put_env(:symphony_elixir, :tracker_module, FakeLinearIntakeTracker)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    state = Orchestrator.sync_github_issue_intake_for_test(%Orchestrator.State{})
    assert %Task{ref: ref} = state.github_intake_task
    last_sync_ms = state.last_github_intake_sync_ms

    assert_receive(
      {:DOWN, ^ref, :process, _pid, {%RuntimeError{message: "github intake failed"}, _stack}},
      5_000
    )

    log =
      capture_log(fn ->
        {:noreply, state} =
          Orchestrator.handle_info(
            {:DOWN, ref, :process, state.github_intake_task.pid, {%RuntimeError{message: "github intake failed"}, []}},
            state
          )

        assert state.github_intake_task == nil
        assert state.last_github_intake_sync_ms == last_sync_ms

        _state = Orchestrator.sync_github_issue_intake_for_test(state)
        refute_received {:github_issue_intake_sync, "Backlog", FakeLinearIntakeAdapter, _attempts}
      end)

    assert log =~ "GitHub issue intake sync task exited before completion"
  end

  test "Approved to Land dry-run planning runs immediately and respects interval throttle" do
    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_tracker = Application.get_env(:symphony_elixir, :tracker_module)
    previous_worker = Application.get_env(:symphony_elixir, :landing_worker)
    previous_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)
    previous_landing_issues = Application.get_env(:symphony_elixir, :landing_planner_issues)
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end

      if is_nil(previous_lookup),
        do: Application.delete_env(:symphony_elixir, :github_pr_lookup),
        else: Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)

      if is_nil(previous_tracker),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker)

      if is_nil(previous_worker),
        do: Application.delete_env(:symphony_elixir, :landing_worker),
        else: Application.put_env(:symphony_elixir, :landing_worker, previous_worker)

      if is_nil(previous_comment_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_comment_recipient)

      if is_nil(previous_landing_issues),
        do: Application.delete_env(:symphony_elixir, :landing_planner_issues),
        else: Application.put_env(:symphony_elixir, :landing_planner_issues, previous_landing_issues)
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      poll_interval_ms: 50,
      landing_interval_ms: 1_000,
      repository_default: "octo/repo"
    )

    issue = %Issue{
      id: "issue-landing",
      identifier: "LAB-LAND",
      title: "Ready to land",
      state: "Approved to Land",
      branch_name: "lab-land"
    }

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeLandingPrLookup)
    Application.put_env(:symphony_elixir, :tracker_module, FakeLandingTracker)
    Application.put_env(:symphony_elixir, :landing_worker, FakeLandingWorker)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())
    Application.put_env(:symphony_elixir, :landing_planner_issues, [issue])

    state = Orchestrator.plan_approved_landings_for_test(%Orchestrator.State{})
    assert is_integer(state.last_landing_plan_ms)
    assert [%{issue_identifier: "LAB-LAND", queue_position: 1, planned_action: "merge", blocker: "none"}] = state.landing_queue
    assert_receive {:landing_fetch_states, ["Approved to Land"]}
    assert_receive {:landing_pr_lookup, "octo/repo", "LAB-LAND", "lab-land"}
    assert_receive {:landing_comment, "issue-landing", body}
    assert body =~ "Symphony Approved to Land dry-run plan"
    assert_receive {:landing_worker_execute, true, 1}

    _state = Orchestrator.plan_approved_landings_for_test(state)
    refute_receive {:landing_fetch_states, ["Approved to Land"]}, 100

    due_state = %{state | last_landing_plan_ms: System.monotonic_time(:millisecond) - 1_001}
    _state = Orchestrator.plan_approved_landings_for_test(due_state)
    assert_receive {:landing_fetch_states, ["Approved to Land"]}, 200
  end

  test "Done sync runs immediately and respects interval throttle" do
    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
    previous_tracker = Application.get_env(:symphony_elixir, :tracker_module)
    previous_state_recipient = Application.get_env(:symphony_elixir, :tracker_state_update_recipient)
    previous_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end

      if is_nil(previous_lookup),
        do: Application.delete_env(:symphony_elixir, :github_pr_lookup),
        else: Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)

      if is_nil(previous_github_issue),
        do: Application.delete_env(:symphony_elixir, :github_issue),
        else: Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)

      if is_nil(previous_tracker),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker)

      if is_nil(previous_state_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_state_update_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_state_update_recipient, previous_state_recipient)

      if is_nil(previous_comment_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_comment_recipient)
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_team_key: "LAB",
      tracker_all_projects: true,
      repository_default: "octo/repo",
      repository_project_routes: %{"octo/repo" => ["Symphony"]},
      poll_interval_ms: 50,
      done_sync_interval_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupMismatchedMergedLinkedPr)
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerDoneSyncImplementationIssue)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(%Orchestrator.State{})
    assert is_integer(state.last_done_sync_ms)
    assert_receive {:post_merge_fetch_states, state_names}, 200
    assert "In Progress" in state_names
    assert_receive {:post_merge_fetch_states, ["Done"]}, 200

    _state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(state)
    refute_receive {:post_merge_fetch_states, _state_names}, 100

    due_state = %{state | last_done_sync_ms: System.monotonic_time(:millisecond) - 1_001}
    _state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(due_state)
    assert_receive {:post_merge_fetch_states, _state_names}, 200
    assert_receive {:post_merge_fetch_states, ["Done"]}, 200
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

    snapshot = GenServer.call(pid, :snapshot, 15_000)

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

    snapshot = GenServer.call(pid, :snapshot, 15_000)
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

  test "orchestrator poll cycle preserves state when the cycle body raises" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleExceptionGuardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: false}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}} when is_integer(due_in_ms) ->
                   true

                 _ ->
                   false
               end,
               1_000
             )

    issue = %Issue{
      id: "issue-poll-guard",
      identifier: "LAB-POLL-GUARD",
      title: "Preserve running state",
      state: "In Progress"
    }

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    worker_ref = Process.monitor(worker_pid)

    running_entry = %{
      pid: worker_pid,
      ref: worker_ref,
      identifier: issue.identifier,
      issue: issue,
      branch_name: "lab-poll-guard",
      workspace_path: "/tmp/lab-poll-guard",
      session_id: "thread-poll-guard",
      codex_app_server_pid: nil,
      codex_input_tokens: nil,
      codex_output_tokens: nil,
      codex_total_tokens: nil,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }

    retry_attempt = %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 5_000}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 5_000,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil,
          running: %{"issue-poll-guard" => running_entry},
          claimed: MapSet.put(state.claimed, "issue-poll-guard"),
          retry_attempts: %{"issue-poll-guard" => retry_attempt}
      }
    end)

    log =
      capture_log(fn ->
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: "invalid"
        )

        send(pid, :run_poll_cycle)
        _state_after_poll = :sys.get_state(pid, 15_000)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 5_000
        )

        assert %{
                 polling: %{checking?: false, next_poll_in_ms: next_poll_in_ms},
                 running: [%{issue_id: "issue-poll-guard", identifier: "LAB-POLL-GUARD"}]
               } =
                 wait_for_snapshot(
                   pid,
                   fn
                     %{
                       polling: %{checking?: false, next_poll_in_ms: due_in_ms},
                       running: [%{issue_id: "issue-poll-guard"}]
                     }
                     when is_integer(due_in_ms) ->
                       true

                     _ ->
                       false
                   end,
                   1_000
                 )

        assert next_poll_in_ms >= 0
        assert Process.alive?(pid)
      end)

    assert log =~ "Orchestrator poll cycle crashed; preserving orchestrator state"
    assert log =~ "Invalid WORKFLOW.md config"

    state = :sys.get_state(pid, 15_000)
    assert Map.has_key?(state.running, "issue-poll-guard")
    assert MapSet.member?(state.claimed, "issue-poll-guard")
    assert %{"issue-poll-guard" => %{attempt: 1, due_at_ms: due_at_ms}} = state.retry_attempts
    assert is_integer(due_at_ms)
    assert state.poll_check_in_progress == false

    send(worker_pid, :stop)
    Process.demonitor(worker_ref, [:flush])
  end

  test "orchestrator state guard preserves state when the cycle body throws" do
    state = %Orchestrator.State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 2,
      poll_check_in_progress: true,
      running: %{"issue-poll-throw" => %{identifier: "LAB-POLL-THROW"}},
      claimed: MapSet.new(["issue-poll-throw"]),
      retry_attempts: %{"issue-poll-throw" => %{attempt: 1, due_at_ms: 123}}
    }

    log =
      capture_log(fn ->
        assert ^state =
                 Orchestrator.preserve_orchestrator_state_for_test(state, "poll cycle", fn _state ->
                   throw({:unexpected_payload, "missing field"})
                 end)
      end)

    assert log =~ "Orchestrator poll cycle aborted (:throw); preserving orchestrator state"
    assert log =~ "{:unexpected_payload, \"missing field\"}"
  end

  test "orchestrator tick preserves state when runtime config refresh raises" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      max_concurrent_agents: 7
    )

    orchestrator_name = Module.concat(__MODULE__, :TickExceptionGuardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: false}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}} when is_integer(due_in_ms) ->
                   true

                 _ ->
                   false
               end,
               1_000
             )

    issue = %Issue{
      id: "issue-tick-guard",
      identifier: "LAB-TICK-GUARD",
      title: "Preserve tick state",
      state: "In Progress"
    }

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    worker_ref = Process.monitor(worker_pid)

    running_entry = %{
      pid: worker_pid,
      ref: worker_ref,
      identifier: issue.identifier,
      issue: issue,
      branch_name: "lab-tick-guard",
      workspace_path: "/tmp/lab-tick-guard",
      session_id: "thread-tick-guard",
      codex_app_server_pid: nil,
      codex_input_tokens: nil,
      codex_output_tokens: nil,
      codex_total_tokens: nil,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }

    retry_attempt = %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 5_000}
    tick_token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 5_000,
          max_concurrent_agents: 7,
          poll_check_in_progress: false,
          next_poll_due_at_ms: System.monotonic_time(:millisecond) + 5_000,
          tick_timer_ref: nil,
          tick_token: tick_token,
          running: %{"issue-tick-guard" => running_entry},
          claimed: MapSet.put(state.claimed, "issue-tick-guard"),
          retry_attempts: %{"issue-tick-guard" => retry_attempt}
      }
    end)

    log =
      capture_log(fn ->
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: "invalid"
        )

        send(pid, {:tick, tick_token})

        state_after_tick =
          wait_for_orchestrator_state(pid, fn
            %{
              poll_check_in_progress: false,
              tick_token: observed_tick_token,
              running: %{"issue-tick-guard" => _running_entry},
              retry_attempts: %{"issue-tick-guard" => %{attempt: 1}}
            } ->
              observed_tick_token != tick_token

            _ ->
              false
          end)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 5_000,
          max_concurrent_agents: 7
        )

        assert Process.alive?(pid)
        assert state_after_tick.poll_interval_ms == 5_000
        assert state_after_tick.max_concurrent_agents == 7
        assert state_after_tick.tick_token != tick_token
      end)

    assert log =~ "Orchestrator tick runtime config refresh crashed; preserving orchestrator state"
    assert log =~ "Invalid WORKFLOW.md config"

    state = :sys.get_state(pid, 15_000)
    assert Map.has_key?(state.running, "issue-tick-guard")
    assert MapSet.member?(state.claimed, "issue-tick-guard")
    assert %{"issue-tick-guard" => %{attempt: 1, due_at_ms: due_at_ms}} = state.retry_attempts
    assert is_integer(due_at_ms)
    assert state.poll_interval_ms == 5_000
    assert state.max_concurrent_agents == 7
    assert state.poll_check_in_progress == false

    send(worker_pid, :stop)
    Process.demonitor(worker_ref, [:flush])
  end

  test "orchestrator periodically cleans dirty workspace quarantines after startup" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-periodic-dirty-cleanup-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      workspace_root: workspace_root,
      dirty_workspace_retention_days: 7
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :PeriodicDirtyCleanupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    expired_dirty = Path.join(workspace_root, "LAB-OLD.dirty-20260501-000000-42")
    File.mkdir_p!(expired_dirty)
    File.write!(Path.join(expired_dirty, "marker.txt"), "remove")

    :sys.replace_state(pid, fn state ->
      %{state | last_dirty_workspace_cleanup_ms: System.monotonic_time(:millisecond) - :timer.hours(25)}
    end)

    send(pid, :run_poll_cycle)

    wait_for_orchestrator_state(pid, fn state ->
      state.poll_check_in_progress == false and not File.exists?(expired_dirty)
    end)

    refute File.exists?(expired_dirty)
  end

  test "orchestrator snapshot exposes latest dirty workspace cleanup failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-periodic-dirty-cleanup-status-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(test_root)
    File.mkdir_p!(workspace_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    printf 'remote cleanup failed\\n'
    exit 23
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      workspace_root: workspace_root,
      dirty_workspace_retention_days: 7,
      worker_ssh_hosts: ["worker-01"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :PeriodicDirtyCleanupStatusOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{state | last_dirty_workspace_cleanup_ms: System.monotonic_time(:millisecond) - :timer.hours(25)}
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_orchestrator_state(pid, fn state ->
        cleanup = Map.get(state, :last_dirty_workspace_cleanup)

        match?(
          %{status: :ok, failed_count: 1, remote: [%{worker_host: "worker-01", status: :error}]},
          cleanup
        ) and state.poll_check_in_progress == false
      end)
      |> then(fn _state -> Orchestrator.snapshot(orchestrator_name, 15_000) end)

    assert %{
             dirty_workspace_cleanup: %{
               status: :ok,
               failed_count: 1,
               remote: [%{worker_host: "worker-01", status: :error}]
             }
           } = snapshot

    assert %{
             dirty_workspace_cleanup: %{
               status: :ok,
               failed_count: 1,
               remote: [%{worker_host: "worker-01", status: :error}]
             }
           } = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 15_000)
  end

  test "orchestrator snapshot keeps unroutable issues when agent slots are full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      poll_interval_ms: 5_000,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{"yakisoba666rasb-star/symphony" => ["Symphony"]}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :UnroutableNoSlotsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{state | max_concurrent_agents: 0, running: %{}, claimed: MapSet.new(), blocked: %{}, unroutable: []}
    end)

    issue = %Issue{
      id: "issue-no-route-no-slots",
      identifier: "LAB-NO-ROUTE",
      title: "Missing route should stay visible",
      state: "Todo",
      project_name: "auto_template",
      project_slug: "899e25e6ce02"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    send(pid, :run_poll_cycle)

    assert %{
             running: [],
             unroutable: [
               %{
                 identifier: "LAB-NO-ROUTE",
                 reason: "missing_project_route",
                 project_name: "auto_template"
               }
             ]
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{unroutable: [%{identifier: "LAB-NO-ROUTE"}]} -> true
                 _ -> false
               end,
               1_000
             )
  end

  test "orchestrator hands off existing open PR before dispatching a new worker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo"
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupOpenIssuePr)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-dispatch-open-pr-guard"
    issue_url = "https://linear.app/example/issue/LAB-391/retry-policy"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-391",
      title: "Unify retry policy",
      state: "In Progress",
      url: issue_url,
      branch_name: "aenima611111/lab-391-linear-generated-branch",
      description: "Repo: octo/repo"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :DispatchOpenPrGuardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-391", ^issue_url, "aenima611111/lab-391-linear-generated-branch", []},
                   1_000

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "https://github.com/octo/repo/pull/83"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000

    state =
      wait_for_orchestrator_state(pid, fn state ->
        MapSet.member?(state.completed, issue_id)
      end)

    assert state.running == %{}
    assert state.blocked == %{}
    assert MapSet.member?(state.completed, issue_id)
  end

  test "orchestrator dispatches landing repair issues instead of handing off dirty PRs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo",
      landing_enabled: true,
      landing_execute_enabled: false,
      landing_blocked_state: "Merge Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_agent_runner = Application.get_env(:symphony_elixir, :agent_runner)
    previous_agent_runner_recipient = Application.get_env(:symphony_elixir, :agent_runner_recipient)
    previous_tracker_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end

      if is_nil(previous_agent_runner) do
        Application.delete_env(:symphony_elixir, :agent_runner)
      else
        Application.put_env(:symphony_elixir, :agent_runner, previous_agent_runner)
      end

      if is_nil(previous_agent_runner_recipient) do
        Application.delete_env(:symphony_elixir, :agent_runner_recipient)
      else
        Application.put_env(:symphony_elixir, :agent_runner_recipient, previous_agent_runner_recipient)
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

      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupDirtyOpenIssuePr)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-landing-repair-dirty-pr"
    issue_url = "https://linear.app/example/issue/LAB-490/async-dirty-cleanup"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-490",
      title: "Async dirty cleanup repair",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-490-async-dirty-cleanup",
      description: "Repo: octo/repo",
      labels: ["landing-blocked", "landing-conflict"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :LandingRepairDirtyPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-490", ^issue_url, "lab-490-async-dirty-cleanup", []},
                   1_000

    assert_receive {:agent_runner_called, %{id: ^issue_id, state: "In Progress"}, opts}, 1_000
    assert opts[:extra_prompt] =~ "Landing repair context"
    assert opts[:extra_prompt] =~ "https://github.com/octo/repo/pull/200"
    assert opts[:extra_prompt] =~ "mergeability=DIRTY"
    assert opts[:extra_prompt] =~ "return the Linear issue to In Review"
    assert opts[:extra_prompt] =~ "Do not merge the PR"
  end

  test "orchestrator reconciles landing repair issues by dispatching dirty PRs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo",
      landing_enabled: true,
      landing_execute_enabled: false,
      landing_blocked_state: "Merge Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    previous_env =
      for key <- [
            :github_pr_lookup,
            :agent_runner,
            :agent_runner_recipient,
            :agent_runner_blocking_recipient,
            :tracker_module,
            :tracker_comment_recipient,
            :active_open_pr_reconcile_issues,
            :memory_tracker_issues,
            :fake_open_issue_pr_merge_state
          ],
          do: {key, Application.get_env(:symphony_elixir, key)}

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupDirtyOpenIssuePr)
    Application.put_env(:symphony_elixir, :fake_open_issue_pr_merge_state, "DIRTY")
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-landing-repair-reconcile-dirty-pr"
    issue_url = "https://linear.app/example/issue/LAB-490/async-dirty-cleanup"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-490",
      title: "Async dirty cleanup repair",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-490-async-dirty-cleanup",
      description: "Repo: octo/repo",
      labels: ["landing-blocked", "landing-conflict"]
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :LandingRepairReconcileDirtyPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:active_open_pr_reconcile_fetch_called, ["In Progress"]}, 1_000

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-490", ^issue_url, "lab-490-async-dirty-cleanup", []},
                   1_000

    assert_receive {:agent_runner_called, %{id: ^issue_id, state: "In Progress"}, opts}, 1_000
    assert opts[:extra_prompt] =~ "Landing repair context"
    assert opts[:extra_prompt] =~ "https://github.com/octo/repo/pull/200"
    assert opts[:extra_prompt] =~ "mergeability=DIRTY"
    assert opts[:extra_prompt] =~ "return the Linear issue to In Review"
    assert opts[:extra_prompt] =~ "Do not merge the PR"
  end

  test "orchestrator preserves running landing repair workers during dirty PR reconcile" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 50,
      repository_default: "octo/repo",
      landing_enabled: true,
      landing_execute_enabled: false,
      landing_blocked_state: "Merge Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    previous_env =
      for key <- [
            :github_pr_lookup,
            :agent_runner,
            :agent_runner_recipient,
            :tracker_module,
            :tracker_comment_recipient,
            :active_open_pr_reconcile_issues,
            :memory_tracker_issues,
            :fake_open_issue_pr_merge_state
          ],
          do: {key, Application.get_env(:symphony_elixir, key)}

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupDirtyOpenIssuePr)
    Application.put_env(:symphony_elixir, :fake_open_issue_pr_merge_state, "DIRTY")
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecordsBlocking)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :agent_runner_blocking_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-landing-repair-reconcile-running-dirty-pr"
    issue_url = "https://linear.app/example/issue/LAB-490/async-dirty-cleanup"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-490",
      title: "Async dirty cleanup repair",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-490-async-dirty-cleanup",
      description: "Repo: octo/repo",
      labels: ["landing-blocked", "landing-conflict"]
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :LandingRepairReconcileRunningDirtyPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:agent_runner_called, %{id: ^issue_id, state: "In Progress"}, opts}, 1_000
    assert opts[:extra_prompt] =~ "Landing repair context"
    assert opts[:extra_prompt] =~ "https://github.com/octo/repo/pull/200"
    assert opts[:extra_prompt] =~ "mergeability=DIRTY"
    assert_receive {:agent_runner_blocking, runner_pid, ^issue_id, runner_ref}, 1_000

    state =
      wait_for_orchestrator_state(pid, fn state ->
        Map.has_key?(state.running, issue_id)
      end)

    assert Map.has_key?(state.running, issue_id)

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])

    assert_receive {:active_open_pr_reconcile_fetch_called, ["In Progress"]}, 1_000

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-490", ^issue_url, "lab-490-async-dirty-cleanup", []},
                   1_000

    refute_receive {:agent_runner_called, %{id: ^issue_id}, _opts}, 300

    state = :sys.get_state(pid, 15_000)
    assert Map.has_key?(state.running, issue_id)

    send(runner_pid, {:release_agent_runner, runner_ref})
  end

  test "orchestrator defers landing repair reconcile while PR mergeability is unknown" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo",
      landing_enabled: true,
      landing_execute_enabled: false,
      landing_blocked_state: "Merge Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    previous_env =
      for key <- [
            :github_pr_lookup,
            :review_runner,
            :agent_runner,
            :agent_runner_recipient,
            :tracker_module,
            :tracker_state_update_recipient,
            :tracker_comment_recipient,
            :active_open_pr_reconcile_issues,
            :memory_tracker_issues,
            :fake_open_issue_pr_merge_state
          ],
          do: {key, Application.get_env(:symphony_elixir, key)}

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupDirtyOpenIssuePr)
    Application.put_env(:symphony_elixir, :fake_open_issue_pr_merge_state, "UNKNOWN")
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-landing-repair-reconcile-unknown-pr"
    issue_url = "https://linear.app/example/issue/LAB-490/async-dirty-cleanup"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-490",
      title: "Async dirty cleanup repair",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-490-async-dirty-cleanup",
      description: "Repo: octo/repo",
      labels: ["landing-blocked"]
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :LandingRepairReconcileUnknownPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:active_open_pr_reconcile_fetch_called, ["In Progress"]}, 1_000

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-490", ^issue_url, "lab-490-async-dirty-cleanup", []},
                   1_000

    refute_receive {:agent_runner_called, %{id: ^issue_id}, _opts}, 300
    refute_receive {:tracker_state_update_called, ^issue_id, _state}, 300

    state = :sys.get_state(pid, 15_000)
    assert state.running == %{}
    refute MapSet.member?(state.completed, issue_id)
  end

  test "orchestrator defers landing repair reconcile while PR mergeability is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo",
      landing_enabled: true,
      landing_execute_enabled: false,
      landing_blocked_state: "Merge Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    previous_env =
      for key <- [
            :github_pr_lookup,
            :review_runner,
            :agent_runner,
            :agent_runner_recipient,
            :tracker_module,
            :tracker_state_update_recipient,
            :tracker_comment_recipient,
            :active_open_pr_reconcile_issues,
            :memory_tracker_issues,
            :fake_open_issue_pr_merge_state
          ],
          do: {key, Application.get_env(:symphony_elixir, key)}

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupDirtyOpenIssuePr)
    Application.put_env(:symphony_elixir, :fake_open_issue_pr_merge_state, nil)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-landing-repair-reconcile-missing-mergeability-pr"
    issue_url = "https://linear.app/example/issue/LAB-490/async-dirty-cleanup"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-490",
      title: "Async dirty cleanup repair",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-490-async-dirty-cleanup",
      description: "Repo: octo/repo",
      labels: ["landing-blocked"]
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :LandingRepairReconcileMissingMergeabilityPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:active_open_pr_reconcile_fetch_called, ["In Progress"]}, 1_000

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-490", ^issue_url, "lab-490-async-dirty-cleanup", []},
                   1_000

    refute_receive {:agent_runner_called, %{id: ^issue_id}, _opts}, 300
    refute_receive {:tracker_state_update_called, ^issue_id, _state}, 300

    state = :sys.get_state(pid, 15_000)
    assert state.running == %{}
    refute MapSet.member?(state.completed, issue_id)
  end

  test "orchestrator reconciles in-progress issues with existing open PRs after restart" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)
    previous_reconcile_issues = Application.get_env(:symphony_elixir, :active_open_pr_reconcile_issues)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

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

      if is_nil(previous_reconcile_issues) do
        Application.delete_env(:symphony_elixir, :active_open_pr_reconcile_issues)
      else
        Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, previous_reconcile_issues)
      end

      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupOpenIssuePr)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-active-open-pr-reconcile"
    issue_url = "https://linear.app/example/issue/LAB-391/retry-policy"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-391",
      title: "Unify retry policy",
      state: "In Progress",
      url: issue_url,
      branch_name: "aenima611111/lab-391-linear-generated-branch",
      description: "Repo: octo/repo"
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :ActiveOpenPrReconcileOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:active_open_pr_reconcile_fetch_called, ["In Progress"]}, 1_000

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-391", ^issue_url, "aenima611111/lab-391-linear-generated-branch", []},
                   1_000

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "https://github.com/octo/repo/pull/83"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000

    state =
      wait_for_orchestrator_state(pid, fn state ->
        MapSet.member?(state.completed, issue_id)
      end)

    assert state.running == %{}
    assert state.blocked == %{}
    assert MapSet.member?(state.completed, issue_id)
  end

  test "orchestrator stops running issue and starts review handoff when ready PR appears" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 5_000,
      repository_default: "octo/repo"
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)
    previous_reconcile_issues = Application.get_env(:symphony_elixir, :active_open_pr_reconcile_issues)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

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

      if is_nil(previous_reconcile_issues) do
        Application.delete_env(:symphony_elixir, :active_open_pr_reconcile_issues)
      else
        Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, previous_reconcile_issues)
      end

      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupOpenIssuePr)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerActiveOpenPrReconcile)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-running-open-pr-reconcile"
    issue_url = "https://linear.app/example/issue/LAB-391/retry-policy"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-391",
      title: "Unify retry policy",
      state: "In Progress",
      url: issue_url,
      branch_name: "aenima611111/lab-391-linear-generated-branch",
      description: "Repo: octo/repo"
    }

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :RunningOpenPrReconcileOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    worker_ref = Process.monitor(worker_pid)
    started_at = DateTime.utc_now()
    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: worker_pid,
      ref: worker_ref,
      identifier: issue.identifier,
      issue: issue,
      branch_name: issue.branch_name,
      workspace_path: "/tmp/lab-391-running-ready-pr",
      session_id: "thread-running-open-pr",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _state ->
      %{
        initial_state
        | running: Map.put(initial_state.running, issue_id, running_entry),
          claimed: MapSet.put(initial_state.claimed, issue_id)
      }
    end)

    Application.put_env(:symphony_elixir, :active_open_pr_reconcile_issues, [issue])

    send(pid, :run_poll_cycle)

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-391", ^issue_url, "aenima611111/lab-391-linear-generated-branch", []},
                   1_000

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "https://github.com/octo/repo/pull/83"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000

    refute Process.alive?(worker_pid)

    state = :sys.get_state(pid, 15_000)
    assert state.running == %{}
    assert state.blocked == %{}
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.completed, issue_id)
  end

  test "orchestrator moves active and review issues with merged linked PR attachments to Done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
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

      if is_nil(previous_github_issue) do
        Application.delete_env(:symphony_elixir, :github_issue)
      else
        Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)
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
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
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
    state = :sys.get_state(pid, 15_000)

    assert_receive {:post_merge_fetch_states, state_names}, 200
    assert "Todo" in state_names
    assert "In Progress" in state_names
    assert "In Review" in state_names

    assert_receive {:merged_pr_lookup_called, ["https://github.com/octo/repo/pull/200"]}, 200
    refute_receive {:merged_pr_lookup_called, ["https://github.com/octo/repo/issues/381"]}, 100

    assert_receive {:merged_issue_pr_lookup_called, "MT-381", "https://linear.app/example/issue/MT-381/body-linked-merged-pr", "lab-381-body-linked"},
                   200

    assert_receive {:merged_issue_pr_lookup_called, "MT-382", "https://linear.app/example/issue/MT-382/no-pr-evidence", nil},
                   200

    assert_receive {:tracker_state_update_called, "issue-review-merged", "Done"}, 200
    assert_receive {:tracker_state_update_called, "issue-progress-merged", "Done"}, 200
    assert_receive {:tracker_state_update_called, "issue-body-linked-merged", "Done"}, 200
    assert_receive {:tracker_state_update_called, "issue-identifier-url-only", "Done"}, 200

    for issue_id <- [
          "issue-review-merged",
          "issue-progress-merged",
          "issue-body-linked-merged",
          "issue-identifier-url-only"
        ] do
      assert_receive {:tracker_remove_labels_called, ^issue_id, labels}, 200
      assert "landing-blocked" in labels
      assert "landing-conflict" in labels
      assert "landing-checks-failing" in labels
      assert "landing-needs-review" in labels
      assert "landing-draft" in labels
      assert "landing-stale-pr" in labels
    end

    assert_receive {:github_issue_close_called, "octo/repo", "https://github.com/octo/repo/issues/381", close_comment}, 200
    assert close_comment =~ "https://github.com/octo/repo/pull/201"
    assert close_comment =~ "MT-381"

    assert MapSet.member?(state.completed, "issue-review-merged")
    assert MapSet.member?(state.completed, "issue-progress-merged")
    assert MapSet.member?(state.completed, "issue-body-linked-merged")
    assert MapSet.member?(state.completed, "issue-identifier-url-only")
  end

  test "Done sync closes source GitHub issues for Linear issues already in Done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
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

      if is_nil(previous_github_issue) do
        Application.delete_env(:symphony_elixir, :github_issue)
      else
        Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)
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
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerAlreadyDoneSourceIssue)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(%Orchestrator.State{})

    assert_receive {:post_merge_fetch_states, active_state_names}, 200
    assert "In Progress" in active_state_names
    refute "Done" in active_state_names

    assert_receive {:post_merge_fetch_states, done_state_names}, 200
    assert done_state_names == ["Done"]

    assert_receive {:github_issue_closed_at_called, "octo/repo", "https://github.com/octo/repo/issues/381"}, 200

    assert_receive {:merged_issue_pr_lookup_called, "MT-381", "https://linear.app/example/issue/MT-381/body-linked-merged-pr", "lab-381-body-linked"},
                   200

    assert_receive {:github_issue_close_called, "octo/repo", "https://github.com/octo/repo/issues/381", close_comment}, 200
    assert close_comment =~ "https://github.com/octo/repo/pull/201"
    assert close_comment =~ "MT-381"

    refute_receive {:tracker_state_update_called, "issue-already-done-source", "Done"}, 100
    refute MapSet.member?(state.completed, "issue-already-done-source")

    assert MapSet.member?(
             state.done_source_github_issue_closes,
             {"issue-already-done-source", "https://github.com/octo/repo/issues/381"}
           )

    flush_done_source_close_messages = fn flush ->
      receive do
        {:post_merge_fetch_states, _state_names} -> flush.(flush)
        {:github_issue_closed_at_called, _repo, _issue_url} -> flush.(flush)
        {:merged_issue_pr_lookup_called, _identifier, _issue_url, _branch_name} -> flush.(flush)
        {:github_issue_close_called, _repo, _issue_url, _comment} -> flush.(flush)
      after
        0 -> :ok
      end
    end

    flush_done_source_close_messages.(flush_done_source_close_messages)

    due_state = %{state | last_done_sync_ms: nil}
    _state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(due_state)

    assert_receive {:post_merge_fetch_states, _active_state_names}, 200
    assert_receive {:post_merge_fetch_states, ["Done"]}, 200
    refute_receive {:github_issue_closed_at_called, "octo/repo", "https://github.com/octo/repo/issues/381"}, 100
    refute_receive {:merged_issue_pr_lookup_called, "MT-381", _issue_url, _branch_name}, 100
    refute_receive {:github_issue_close_called, "octo/repo", "https://github.com/octo/repo/issues/381", _close_comment}, 100
  end

  test "Done sync skips merged PR lookup when source GitHub issue is already closed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)
    previous_tracker_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup),
        do: Application.delete_env(:symphony_elixir, :github_pr_lookup),
        else: Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)

      if is_nil(previous_github_issue),
        do: Application.delete_env(:symphony_elixir, :github_issue),
        else: Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)

      if is_nil(previous_tracker_module),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)

      if is_nil(previous_tracker_comment_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else: Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_tracker_comment_recipient)
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupMergedLinkedPr)
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueAlreadyClosed)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerAlreadyDoneSourceIssue)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    state = Orchestrator.sync_merged_linked_pull_requests_to_done_for_test(%Orchestrator.State{})

    assert_receive {:post_merge_fetch_states, _active_state_names}, 200
    assert_receive {:post_merge_fetch_states, ["Done"]}, 200
    assert_receive {:github_issue_closed_at_called, "octo/repo", "https://github.com/octo/repo/issues/381"}, 200
    refute_receive {:merged_issue_pr_lookup_called, "MT-381", _issue_url, _branch_name}, 100
    refute_receive {:github_issue_close_called, "octo/repo", "https://github.com/octo/repo/issues/381", _close_comment}, 100

    assert MapSet.member?(
             state.done_source_github_issue_closes,
             {"issue-already-done-source", "https://github.com/octo/repo/issues/381"}
           )
  end

  test "Done sync prefers merged implementation PR evidence over unrelated linked PR attachments" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
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

      if is_nil(previous_github_issue) do
        Application.delete_env(:symphony_elixir, :github_issue)
      else
        Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupImplementationMergedPr)
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerDoneSyncImplementationIssue)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :ImplementationPrDoneSyncOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert_receive {:post_merge_fetch_states, state_names}, 200
    assert "In Progress" in state_names

    assert_receive {:merged_issue_pr_lookup_called, "LAB-396", "https://linear.app/example/issue/LAB-396/implementation", "lab-396-implementation"},
                   200

    refute_receive {:merged_pr_lookup_called, ["https://github.com/octo/repo/pull/87"]}, 100
    assert_receive {:tracker_state_update_called, "issue-lab-396", "Done"}, 200

    assert_receive {:github_issue_close_called, "octo/repo", _source_issue_url, close_comment}, 200
    assert close_comment =~ "https://github.com/octo/repo/pull/88"
    refute close_comment =~ "https://github.com/octo/repo/pull/87"

    assert MapSet.member?(state.completed, "issue-lab-396")
  end

  test "Done sync rejects merged linked PR attachment when branch differs from implementation issue" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
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

      if is_nil(previous_github_issue) do
        Application.delete_env(:symphony_elixir, :github_issue)
      else
        Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupMismatchedMergedLinkedPr)
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerDoneSyncImplementationIssue)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :MismatchedLinkedPrDoneSyncOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert_receive {:merged_issue_pr_lookup_called, "LAB-396", "https://linear.app/example/issue/LAB-396/implementation", "lab-396-implementation"},
                   200

    assert_receive {:open_issue_pr_lookup_called, "LAB-396", "https://linear.app/example/issue/LAB-396/implementation", "lab-396-implementation", []},
                   200

    assert_receive {:merged_pr_lookup_called, ["https://github.com/octo/repo/pull/87"]}, 200
    refute_receive {:tracker_state_update_called, "issue-lab-396", "Done"}, 200
    refute_receive {:github_issue_close_called, "octo/repo", _source_issue_url, _close_comment}, 100

    refute MapSet.member?(state.completed, "issue-lab-396")
  end

  test "Done sync ignores ambiguous linked PR attachments when branch issue evidence does not match" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_github_issue = Application.get_env(:symphony_elixir, :github_issue)
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

      if is_nil(previous_github_issue) do
        Application.delete_env(:symphony_elixir, :github_issue)
      else
        Application.put_env(:symphony_elixir, :github_issue, previous_github_issue)
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupAmbiguousLinkedPr)
    Application.put_env(:symphony_elixir, :github_issue, FakeGitHubIssueCloser)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerDoneSyncAmbiguousLinkedIssue)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :AmbiguousLinkedPrDoneSyncOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert_receive {:merged_issue_pr_lookup_called, "LAB-467", "https://linear.app/example/issue/LAB-467/meta", "lab-467-implementation"},
                   200

    assert_receive {:open_issue_pr_lookup_called, "LAB-467", "https://linear.app/example/issue/LAB-467/meta", "lab-467-implementation", []},
                   200

    assert_receive {:merged_pr_lookup_called,
                    [
                      "https://github.com/octo/repo/pull/166",
                      "https://github.com/octo/repo/pull/154"
                    ]},
                   200

    refute_receive {:tracker_state_update_called, "issue-lab-467", "Done"}, 200
    refute_receive {:github_issue_close_called, "octo/repo", _source_issue_url, _close_comment}, 100

    refute Map.has_key?(state.retry_attempts, "issue-lab-467")
    refute Map.has_key?(state.blocked, "issue-lab-467")
    refute MapSet.member?(state.completed, "issue-lab-467")
  end

  test "Done sync failures use retry policy cap and reset when PR evidence changes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 60_000,
      done_sync_interval_ms: 60_000,
      retry_max_done_sync_attempts: 2
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)
    previous_attachment_url = Application.get_env(:symphony_elixir, :done_sync_attachment_url)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient =
      Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_lookup),
        do: Application.delete_env(:symphony_elixir, :github_pr_lookup),
        else: Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)

      if is_nil(previous_tracker_module),
        do: Application.delete_env(:symphony_elixir, :tracker_module),
        else: Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)

      if is_nil(previous_attachment_url),
        do: Application.delete_env(:symphony_elixir, :done_sync_attachment_url),
        else: Application.put_env(:symphony_elixir, :done_sync_attachment_url, previous_attachment_url)

      if is_nil(previous_tracker_state_update_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_state_update_recipient),
        else:
          Application.put_env(
            :symphony_elixir,
            :tracker_state_update_recipient,
            previous_tracker_state_update_recipient
          )

      if is_nil(previous_tracker_comment_recipient),
        do: Application.delete_env(:symphony_elixir, :tracker_comment_recipient),
        else:
          Application.put_env(
            :symphony_elixir,
            :tracker_comment_recipient,
            previous_tracker_comment_recipient
          )
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupAnyMergedLinkedPr)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerDoneSyncUpdateError)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :DoneSyncRetryPolicyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue_id = "issue-done-sync-update-error"

    state =
      wait_for_orchestrator_state(pid, fn state ->
        get_in(state.retry_attempts, [issue_id, :attempt]) == 1
      end)

    assert %{policy_context: :done_sync, attempt: 1} = state.retry_attempts[issue_id]
    assert_receive {:tracker_comment_called, ^issue_id, first_attempt_comment}, 500
    assert first_attempt_comment =~ "Symphony warning: merged PR Done sync could not complete"
    assert first_attempt_comment =~ "failed to move Linear issue to Done"

    Application.put_env(
      :symphony_elixir,
      :done_sync_attachment_url,
      "https://github.com/octo/repo/pull/201"
    )

    :sys.replace_state(pid, fn state -> %{state | last_done_sync_ms: nil} end)
    send(pid, :run_poll_cycle)

    state =
      wait_for_orchestrator_state(pid, fn state ->
        get_in(state.retry_attempts, [issue_id, :attempt]) == 1
      end)

    assert %{policy_context: :done_sync, attempt: 1, error: error} = state.retry_attempts[issue_id]
    assert error =~ "failed to move Linear issue to Done"
    assert_receive {:tracker_comment_called, ^issue_id, refreshed_evidence_comment}, 500
    assert refreshed_evidence_comment =~ "Symphony warning: merged PR Done sync could not complete"

    :sys.replace_state(pid, fn state -> %{state | last_done_sync_ms: nil} end)
    send(pid, :run_poll_cycle)

    state =
      wait_for_orchestrator_state(pid, fn state ->
        get_in(state.retry_attempts, [issue_id, :attempt]) == 2
      end)

    assert %{policy_context: :done_sync, attempt: 2} = state.retry_attempts[issue_id]

    :sys.replace_state(pid, fn state -> %{state | last_done_sync_ms: nil} end)
    send(pid, :run_poll_cycle)

    state =
      wait_for_orchestrator_state(pid, fn state ->
        error = get_in(state.blocked, [issue_id, :error])
        is_binary(error) and error =~ "merged PR Done sync retry limit reached (2)"
      end)

    refute Map.has_key?(state.retry_attempts, issue_id)
    assert %{policy_terminal_context: :done_sync, error: error} = state.blocked[issue_id]
    assert error =~ "failed to move Linear issue to Done"
    assert_tracker_comment_contains(issue_id, "merged PR Done sync retry limit reached (2)", 500)
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      stall_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-stall"
    issue = %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

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

    worker_ref = Process.monitor(worker_pid)
    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    stale_progress_ms = System.monotonic_time(:millisecond) - 2_500
    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: issue,
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at,
      last_progress_ms: stale_progress_ms,
      stall_comment_posted?: false
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    retry_started_at_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 5_000

    state =
      wait_for_orchestrator_state(pid, fn state ->
        not Map.has_key?(state.running, issue_id)
      end)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 500
    assert comment =~ "Reason: no progress for"
    assert comment =~ "session=thread-stall-turn-stall"
    assert comment =~ "Attempt count: 1"
    assert comment =~ "Next action: will recycle"

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

  test "running entries are stamped with progress at agent start" do
    issue = %Issue{id: "issue-start-stamp", identifier: "MT-START", state: "In Progress"}
    before_start_ms = System.monotonic_time(:millisecond)
    entry = Orchestrator.running_entry_for_test(issue, attempt: 2, agent_opts: [continuation_count: 1])
    after_start_ms = System.monotonic_time(:millisecond)

    assert entry.last_progress_ms >= before_start_ms
    assert entry.last_progress_ms <= after_start_ms
    assert entry.stall_comment_posted? == false
    assert entry.retry_attempt == 2
    assert entry.continuation_count == 1
  end

  test "orchestrator comments once per stall episode before recycle threshold" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      stall_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-stall-comment"
    issue = %Issue{id: issue_id, identifier: "MT-STALL-COMMENT", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :StallCommentOrchestrator)
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

    stale_progress_ms = System.monotonic_time(:millisecond) - 1_200
    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL-COMMENT",
      issue: issue,
      session_id: "thread-stall-comment",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: :notification,
      started_at: DateTime.utc_now(),
      last_progress_ms: stale_progress_ms,
      stall_comment_posted?: false
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid, 15_000)

    assert Process.alive?(worker_pid)
    assert %{stall_comment_posted?: true} = state.running[issue_id]
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 500
    assert comment =~ "MT-STALL-COMMENT"
    refute Map.has_key?(state.retry_attempts, issue_id)

    send(pid, :tick)
    Process.sleep(100)
    _state = :sys.get_state(pid, 15_000)

    refute_receive {:tracker_comment_called, ^issue_id, _comment}, 200
    assert Process.alive?(worker_pid)

    send(worker_pid, :done)
  end

  test "orchestrator comments once for stalled review handoff before recycle threshold" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 100,
      stall_review_threshold_ms: 5_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-review-handoff-stall-comment"
    issue = %Issue{id: issue_id, identifier: "MT-REVIEW-STALL-COMMENT", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :ReviewHandoffStallCommentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    review_ref = make_ref()
    started_at = DateTime.add(DateTime.utc_now(), -5_200, :millisecond)
    initial_state = :sys.get_state(pid, 15_000)

    pending_metadata = %{
      mode: :normal,
      issue_id: issue_id,
      running_entry: %{
        issue_id: issue_id,
        identifier: issue.identifier,
        issue: issue,
        session_id: "thread-review-stall-comment"
      },
      session_id: "thread-review-stall-comment",
      pr: %{"url" => "https://github.com/acme/repo/pull/120"},
      tracker: FakeTrackerUpdateInReview,
      pid: review_pid,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:pending_review_handoffs, %{review_ref => pending_metadata})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid, 15_000)

    assert Process.alive?(review_pid)
    assert %{review_stall_comment_posted?: true} = state.pending_review_handoffs[review_ref]
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 500
    assert comment =~ "stalled review handoff"
    assert comment =~ "MT-REVIEW-STALL-COMMENT"
    assert comment =~ "pr=https://github.com/acme/repo/pull/120"
    refute Map.has_key?(state.blocked, issue_id)

    send(pid, :tick)
    Process.sleep(100)
    _state = :sys.get_state(pid, 15_000)

    refute_receive {:tracker_comment_called, ^issue_id, _comment}, 200
    assert Process.alive?(review_pid)

    send(review_pid, :done)
  end

  test "orchestrator recycles stalled review handoff through terminal error path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 100,
      stall_review_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-review-handoff-stall-recycle"
    issue = %Issue{id: issue_id, identifier: "MT-REVIEW-STALL-RECYCLE", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :ReviewHandoffStallRecycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    review_ref = make_ref()
    started_at = DateTime.add(DateTime.utc_now(), -2_500, :millisecond)
    initial_state = :sys.get_state(pid, 15_000)

    pending_metadata = %{
      mode: :normal,
      issue_id: issue_id,
      running_entry: %{
        issue_id: issue_id,
        identifier: issue.identifier,
        issue: issue,
        session_id: "thread-review-stall-recycle",
        worker_host: "dm-dev2",
        workspace_path: "/tmp/mt-review-stall-recycle"
      },
      session_id: "thread-review-stall-recycle",
      pr: %{"url" => "https://github.com/acme/repo/pull/121"},
      tracker: FakeTrackerUpdateInReview,
      pid: review_pid,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:pending_review_handoffs, %{review_ref => pending_metadata})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    log =
      capture_log(fn ->
        send(pid, :tick)
        Process.sleep(100)
      end)

    state = :sys.get_state(pid, 15_000)

    refute Process.alive?(review_pid)
    assert state.pending_review_handoffs == %{}
    assert %{identifier: "MT-REVIEW-STALL-RECYCLE", error: error} = state.blocked[issue_id]
    assert error =~ "review loop did not approve PR before In Review handoff"
    assert error =~ "review_handoff_stalled"

    assert_receive {:tracker_comment_called, ^issue_id, stall_comment}, 500
    assert stall_comment =~ "stalled review handoff"
    assert stall_comment =~ "pr=https://github.com/acme/repo/pull/121"

    assert log =~ "Review handoff stalled"
    assert log =~ "issue_id=#{issue_id}"
    assert log =~ "issue_identifier=MT-REVIEW-STALL-RECYCLE"
    assert log =~ "pr=https://github.com/acme/repo/pull/121"
    assert log =~ "elapsed_ms="
  end

  test "codex progress resets stall episode and updates last progress stamp" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      stall_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-stall-reset"
    issue = %Issue{id: issue_id, identifier: "MT-STALL-RESET", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :StallResetOrchestrator)
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

    old_progress_ms = System.monotonic_time(:millisecond) - 1_200
    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL-RESET",
      issue: issue,
      session_id: "thread-stall-reset",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: :notification,
      started_at: DateTime.utc_now(),
      last_progress_ms: old_progress_ms,
      stall_comment_posted?: false
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    assert_receive {:tracker_comment_called, ^issue_id, _comment}, 500

    before_update_ms = System.monotonic_time(:millisecond)

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      message: %{"msg" => "progress"}
    }

    send(pid, {:codex_worker_update, issue_id, update})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{stall_comment_posted?: false}, state.running[issue_id])
      end)

    assert state.running[issue_id].last_progress_ms >= before_update_ms
    assert state.running[issue_id].stall_comment_posted? == false

    send(pid, :tick)
    Process.sleep(100)
    refute_receive {:tracker_comment_called, ^issue_id, _comment}, 200
    assert Process.alive?(worker_pid)

    send(worker_pid, :done)
  end

  test "stall detection disabled leaves stale running workers alone" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      stall_enabled: false,
      stall_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-stall-disabled"
    issue = %Issue{id: issue_id, identifier: "MT-STALL-DISABLED", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :StallDisabledOrchestrator)
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

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL-DISABLED",
      issue: issue,
      session_id: "thread-stall-disabled",
      last_codex_message: nil,
      last_codex_timestamp: DateTime.add(DateTime.utc_now(), -5, :second),
      last_codex_event: :notification,
      started_at: DateTime.add(DateTime.utc_now(), -5, :second),
      last_progress_ms: System.monotonic_time(:millisecond) - 5_000,
      stall_comment_posted?: false
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid, 15_000)

    assert Process.alive?(worker_pid)
    assert Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute_receive {:tracker_comment_called, ^issue_id, _comment}, 200

    send(worker_pid, :done)
  end

  test "orchestrator recycles stalled workers that are waiting on MCP elicitation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      stall_threshold_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())
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
    stale_progress_ms = System.monotonic_time(:millisecond) - 2_500
    initial_state = :sys.get_state(pid, 15_000)

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
      started_at: stale_activity_at,
      last_progress_ms: stale_progress_ms,
      stall_comment_posted?: false
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid, 15_000)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)
    assert Map.has_key?(state.retry_attempts, issue_id)
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 500
    assert comment =~ "MT-MCP"

    refute Map.has_key?(state.blocked, issue_id)
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

    initial_state = :sys.get_state(pid, 15_000)

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

    state_after_first = :sys.get_state(pid, 15_000)
    assert Map.has_key?(state_after_first.running, issue_id)
    refute Map.has_key?(state_after_first.blocked, issue_id)

    send(pid, {:codex_worker_update, issue_id, failed_command_update.()})
    Process.sleep(50)

    state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)

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

    state_after_first =
      wait_for_orchestrator_state(
        pid,
        fn state ->
          Map.has_key?(state.running, issue_id) and not Map.has_key?(state.blocked, issue_id)
        end,
        15_000
      )

    assert Map.has_key?(state_after_first.running, issue_id)
    refute Map.has_key?(state_after_first.blocked, issue_id)

    send(pid, {:codex_worker_update, issue_id, review_update.()})

    state =
      wait_for_orchestrator_state(
        pid,
        fn state ->
          get_in(state.blocked, [issue_id, :error]) == "repeated review fingerprint reached limit 2"
        end,
        15_000
      )

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
    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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
    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      retry_max_handoff_pr_discovery_attempts: 2
    )

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

    initial_state = :sys.get_state(pid, 15_000)

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

    state =
      wait_for_orchestrator_state(pid, fn state ->
        error = get_in(state.blocked, [issue_id, :error])
        is_binary(error) and error =~ "handoff PR discovery retry limit reached"
      end)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{identifier: "MT-NO-PR", error: error} = state.blocked[issue_id]
    assert error =~ "handoff PR discovery retry limit reached (2)"

    assert error =~
             "no GitHub PR found for branch feature/no-pr or linked PR attachments; agent-owned PR is required before In Review handoff"
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

    initial_state = :sys.get_state(pid, 15_000)

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

    state =
      wait_for_orchestrator_state(pid, fn state ->
        get_in(state.blocked, [issue_id, :error]) ==
          "GitHub PR lookup returned unexpected result for branch feature/unexpected-pr-lookup"
      end)

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

    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-MISSING-BRANCH",
             error: "no branch name available for GitHub PR lookup"
           } = state.blocked[issue_id]
  end

  test "orchestrator recovers blocked review handoff when PR becomes discoverable" do
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

    issue_id = "issue-blocked-review-handoff-recovers"
    orchestrator_name = Module.concat(__MODULE__, :BlockedReviewHandoffRecoverOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-RECOVER",
      branch_name: "aenima611111/generated-branch",
      state: "In Progress"
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: "/tmp/mt-blocked-recover",
      session_id: "thread-blocked-recover",
      error: "issue moved to In Review without discoverable GitHub PR for branch aenima611111/generated-branch or linked PR attachments; agent-owned PR is required before handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 5_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 5_000

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "orchestrator recovers Done sync terminal block when an open implementation PR is discoverable" do
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupOpenIssuePr)
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerApproved)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-done-sync-terminal-open-pr-recover"
    issue_url = "https://linear.app/example/issue/LAB-467/merged-pr-done-sync"

    issue = %Issue{
      id: issue_id,
      identifier: "LAB-467",
      title: "Merged PR Done sync issue",
      state: "In Progress",
      url: issue_url,
      branch_name: "lab-467-merged-pr-done-sync",
      description: "Repo: octo/repo",
      attachment_urls: [
        "https://github.com/octo/repo/pull/166",
        "https://github.com/octo/repo/pull/154"
      ]
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      error:
        "merged PR Done sync retry limit reached (5) after attempt 6; blocking issue: " <>
          "failed to inspect linked PR attachment: {:ambiguous_linked_pull_requests, [...]",
      policy_terminal_context: :done_sync,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :DoneSyncBlockedOpenPrRecoverOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))

    assert_receive {:open_issue_pr_lookup_called, "octo/repo", "LAB-467", ^issue_url, "lab-467-merged-pr-done-sync",
                    [
                      "https://github.com/octo/repo/pull/166",
                      "https://github.com/octo/repo/pull/154"
                    ]},
                   1_000

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 5_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "https://github.com/octo/repo/pull/83"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 5_000

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "orchestrator accepts blocked review handoff moved directly to In Review when PR is discoverable" do
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

    issue_id = "issue-blocked-review-handoff-in-review-accepted"
    orchestrator_name = Module.concat(__MODULE__, :BlockedReviewHandoffInReviewAcceptedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    blocked_issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-IN-REVIEW-OK",
      branch_name: "feature/blocked-in-review-ok",
      state: "Rework"
    }

    review_issue = %{blocked_issue | state: "In Review"}

    blocked_entry = %{
      issue_id: issue_id,
      identifier: blocked_issue.identifier,
      issue: blocked_issue,
      worker_host: nil,
      workspace_path: "/tmp/mt-blocked-in-review-ok",
      session_id: "thread-blocked-in-review-ok",
      error: "issue moved to In Review without discoverable GitHub PR for branch feature/blocked-in-review-ok or linked PR attachments; agent-owned PR is required before handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([review_issue], &1))

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
  end

  test "orchestrator re-blocks blocked review handoff moved directly to In Review without PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_review_state: "In Review"
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

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupNone)
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-blocked-review-handoff-in-review-no-pr"
    orchestrator_name = Module.concat(__MODULE__, :BlockedReviewHandoffInReviewNoPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    blocked_issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-IN-REVIEW-NO-PR",
      branch_name: "feature/blocked-in-review-no-pr",
      state: "Rework"
    }

    review_issue = %{blocked_issue | state: "In Review"}

    blocked_entry = %{
      issue_id: issue_id,
      identifier: blocked_issue.identifier,
      issue: blocked_issue,
      worker_host: nil,
      workspace_path: "/tmp/mt-blocked-in-review-no-pr",
      session_id: "thread-blocked-in-review-no-pr",
      error: "issue moved to In Review without discoverable GitHub PR for branch feature/blocked-in-review-no-pr or linked PR attachments; agent-owned PR is required before handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([review_issue], &1))

    assert_receive {:tracker_state_update_called, ^issue_id, "Rework"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "Symphony blocked MT-BLOCKED-IN-REVIEW-NO-PR"
    assert comment =~ "agent-owned PR is required before handoff"

    state = :sys.get_state(pid, 15_000)
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             identifier: "MT-BLOCKED-IN-REVIEW-NO-PR",
             issue: %Issue{state: "Rework"},
             error: "issue moved to In Review without discoverable GitHub PR for branch feature/blocked-in-review-no-pr or linked PR attachments; agent-owned PR is required before handoff"
           } = state.blocked[issue_id]
  end

  test "blocked review handoff reconciliation resets on new evidence and stops at configured cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      retry_max_blocked_review_handoff_attempts: 2
    )

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)

    on_exit(fn ->
      if is_nil(previous_lookup) do
        Application.delete_env(:symphony_elixir, :github_pr_lookup)
      else
        Application.put_env(:symphony_elixir, :github_pr_lookup, previous_lookup)
      end
    end)

    Application.put_env(:symphony_elixir, :github_pr_lookup, FakeGitHubPrLookupNone)

    issue_id = "issue-blocked-review-policy"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-REVIEW-POLICY",
      branch_name: "feature/blocked-review-policy-a",
      state: "In Progress"
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-blocked-review-policy",
      session_id: "thread-blocked-review-policy",
      error: "no GitHub PR found for branch feature/blocked-review-policy-a or linked PR attachments; agent-owned PR is required before In Review handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    state =
      %Orchestrator.State{blocked: %{issue_id => blocked_entry}, claimed: MapSet.new([issue_id])}
      |> then(&Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))

    assert get_in(state.blocked, [issue_id, :policy_attempts, :blocked_review_handoff, :attempts]) == 1

    refreshed_issue = %{issue | branch_name: "feature/blocked-review-policy-b"}

    state = Orchestrator.reconcile_blocked_issue_states_for_test([refreshed_issue], state)
    assert get_in(state.blocked, [issue_id, :policy_attempts, :blocked_review_handoff, :attempts]) == 1

    state = Orchestrator.reconcile_blocked_issue_states_for_test([refreshed_issue], state)
    assert get_in(state.blocked, [issue_id, :policy_attempts, :blocked_review_handoff, :attempts]) == 2

    state = Orchestrator.reconcile_blocked_issue_states_for_test([refreshed_issue], state)
    assert %{policy_terminal_context: :blocked_review_handoff, error: error} = state.blocked[issue_id]
    assert error =~ "blocked review handoff retry limit reached (2)"
  end

  test "orchestrator does not duplicate blocked review guard while review state handoff is pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_review_state: "In Review"
    )

    issue_id = "issue-blocked-review-handoff-in-review-pending"
    orchestrator_name = Module.concat(__MODULE__, :BlockedReviewHandoffInReviewPendingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-IN-REVIEW-PENDING",
      branch_name: "feature/blocked-in-review-pending",
      state: "In Review"
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: %{issue | state: "Rework"},
      worker_host: nil,
      workspace_path: "/tmp/mt-blocked-in-review-pending",
      session_id: "thread-blocked-in-review-pending",
      error: "issue moved to In Review without discoverable GitHub PR for branch feature/blocked-in-review-pending or linked PR attachments; agent-owned PR is required before handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    pending_ref = make_ref()
    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:pending_review_handoffs, %{pending_ref => %{issue_id: issue_id}})
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.claimed, issue_id)
    assert Map.has_key?(state.blocked, issue_id)
    assert %{^pending_ref => %{issue_id: ^issue_id}} = state.pending_review_handoffs
  end

  test "orchestrator keeps pending review handoff when task DOWN normal arrives before result" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    issue_id = "issue-review-down-before-result"
    orchestrator_name = Module.concat(__MODULE__, :ReviewDownBeforeResultOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_ref = make_ref()
    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      Map.put(initial_state, :pending_review_handoffs, %{review_ref => %{issue_id: issue_id}})
    end)

    send(pid, {:DOWN, review_ref, :process, self(), :normal})

    state = :sys.get_state(pid, 15_000)
    assert %{^review_ref => %{issue_id: ^issue_id}} = state.pending_review_handoffs
  end

  test "orchestrator snapshot exposes pending review handoffs as reviewing entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    issue_id = "issue-reviewing-snapshot"
    orchestrator_name = Module.concat(__MODULE__, :ReviewingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_ref = make_ref()
    started_at = DateTime.utc_now()
    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      Map.put(initial_state, :pending_review_handoffs, %{
        review_ref => %{
          mode: :normal,
          issue_id: issue_id,
          running_entry: %{
            identifier: "MT-REVIEWING",
            worker_host: "dm-dev2",
            workspace_path: "/workspaces/MT-REVIEWING"
          },
          session_id: "thread-reviewing",
          pr: %{"url" => "https://github.com/acme/repo/pull/101"},
          started_at: started_at
        }
      })
    end)

    assert %{
             reviewing: [
               %{
                 issue_id: ^issue_id,
                 identifier: "MT-REVIEWING",
                 pr_url: "https://github.com/acme/repo/pull/101",
                 mode: :normal,
                 session_id: "thread-reviewing",
                 started_at: ^started_at,
                 worker_host: "dm-dev2",
                 workspace_path: "/workspaces/MT-REVIEWING"
               }
             ]
           } = Orchestrator.snapshot(orchestrator_name, 5_000)
  end

  test "orchestrator removes pending review handoff after approved result" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    previous_tracker_state_update_recipient =
      Application.get_env(:symphony_elixir, :tracker_state_update_recipient)

    previous_tracker_comment_recipient = Application.get_env(:symphony_elixir, :tracker_comment_recipient)

    on_exit(fn ->
      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end

      if is_nil(previous_tracker_state_update_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_state_update_recipient)
      else
        Application.put_env(:symphony_elixir, :tracker_state_update_recipient, previous_tracker_state_update_recipient)
      end

      if is_nil(previous_tracker_comment_recipient) do
        Application.delete_env(:symphony_elixir, :tracker_comment_recipient)
      else
        Application.put_env(:symphony_elixir, :tracker_comment_recipient, previous_tracker_comment_recipient)
      end
    end)

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-reviewing-approved"
    orchestrator_name = Module.concat(__MODULE__, :ReviewingApprovedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_ref = make_ref()

    running_entry = %{
      issue_id: issue_id,
      identifier: "MT-REVIEW-OK",
      issue: %Issue{id: issue_id, identifier: "MT-REVIEW-OK", state: "In Progress"},
      session_id: "thread-review-ok",
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:pending_review_handoffs, %{
        review_ref => %{
          mode: :normal,
          issue_id: issue_id,
          running_entry: running_entry,
          session_id: "thread-review-ok",
          pr: %{"url" => "https://github.com/acme/repo/pull/102"},
          tracker: FakeTrackerUpdateInReview,
          started_at: DateTime.utc_now()
        }
      })
    end)

    send(pid, {
      review_ref,
      {:ok, %{approved_equivalent: true, blocking_findings: [], tests_required: [], residual_risk: ""}}
    })

    assert_receive {:tracker_state_update_called, ^issue_id, _state_name}

    state = :sys.get_state(pid, 15_000)
    assert state.pending_review_handoffs == %{}
    assert %{reviewing: []} = Orchestrator.snapshot(orchestrator_name, 5_000)
  end

  test "orchestrator removes pending review handoff when task DOWN is not normal" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_tracker_module = Application.get_env(:symphony_elixir, :tracker_module)

    on_exit(fn ->
      if is_nil(previous_tracker_module) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker_module)
      end
    end)

    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)

    issue_id = "issue-reviewing-down"
    orchestrator_name = Module.concat(__MODULE__, :ReviewingDownOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    review_ref = make_ref()

    running_entry = %{
      issue_id: issue_id,
      identifier: "MT-REVIEW-DOWN",
      issue: %Issue{id: issue_id, identifier: "MT-REVIEW-DOWN", state: "In Progress"},
      session_id: "thread-review-down",
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      Map.put(initial_state, :pending_review_handoffs, %{
        review_ref => %{
          mode: :normal,
          issue_id: issue_id,
          running_entry: running_entry,
          session_id: "thread-review-down",
          pr: %{"url" => "https://github.com/acme/repo/pull/103"},
          started_at: DateTime.utc_now()
        }
      })
    end)

    send(pid, {:DOWN, review_ref, :process, self(), :shutdown})

    state = :sys.get_state(pid, 15_000)
    assert state.pending_review_handoffs == %{}
    assert Map.has_key?(state.blocked, issue_id)
  end

  test "review rework opt-in dispatches rework agent for changes requested PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      review_rework_enabled: true,
      review_rework_max_rounds: 2
    )

    Application.put_env(:symphony_elixir, :github_review_status, FakeGitHubReviewChangesRequested)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-review-rework"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-REWORK",
      title: "Rework requested",
      state: "In Review",
      attachment_urls: ["https://github.com/acme/repo/pull/77"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{max_concurrent_agents: 10}
    updated_state = Orchestrator.reconcile_review_rework_requests_for_test(state)

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Progress"}, 500
    assert_receive {:memory_tracker_comment, ^issue_id, comment}, 500
    assert comment =~ "GitHub changes requested"
    assert comment =~ "Please fix the failing retry path."

    assert_receive {:agent_runner_called, %{id: ^issue_id, state: "In Progress"}, opts}, 500
    assert opts[:allow_dirty_existing_workspace] == true
    assert opts[:extra_prompt] =~ "GitHub review rework request"
    assert opts[:extra_prompt] =~ "Please fix the failing retry path."

    assert %{^issue_id => %{rounds: 1, last_review_id: "review-77"}} = updated_state.review_rework_rounds
    assert Map.has_key?(updated_state.running, issue_id)
  end

  test "review rework opt-in dispatches handoff-completed issue for changes requested PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      review_rework_enabled: true,
      review_rework_max_rounds: 2
    )

    Application.put_env(:symphony_elixir, :github_review_status, FakeGitHubReviewChangesRequested)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-review-rework-completed"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-REWORK-COMPLETED",
      title: "Rework requested after handoff",
      state: "In Review",
      attachment_urls: ["https://github.com/acme/repo/pull/77"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{
      max_concurrent_agents: 10,
      completed: MapSet.new([issue_id])
    }

    updated_state = Orchestrator.reconcile_review_rework_requests_for_test(state)

    assert_receive {:memory_tracker_state_update, ^issue_id, "In Progress"}, 500
    assert_receive {:memory_tracker_comment, ^issue_id, comment}, 500
    assert comment =~ "GitHub changes requested"
    assert comment =~ "Please fix the failing retry path."

    assert_receive {:agent_runner_called, %{id: ^issue_id, state: "In Progress"}, opts}, 500
    assert opts[:allow_dirty_existing_workspace] == true
    assert opts[:extra_prompt] =~ "GitHub review rework request"
    assert opts[:extra_prompt] =~ "Please fix the failing retry path."

    assert %{^issue_id => %{rounds: 1, last_review_id: "review-77"}} = updated_state.review_rework_rounds
    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.completed, issue_id)
  end

  test "review rework opt-in ignores PRs without changes requested decision" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      review_rework_enabled: true
    )

    Application.put_env(:symphony_elixir, :github_review_status, FakeGitHubReviewApproved)
    Application.put_env(:symphony_elixir, :agent_runner, FakeAgentRunnerRecords)
    Application.put_env(:symphony_elixir, :agent_runner_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-review-rework-approved",
      identifier: "MT-REWORK-APPROVED",
      state: "In Review",
      attachment_urls: ["https://github.com/acme/repo/pull/77"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{max_concurrent_agents: 10}
    updated_state = Orchestrator.reconcile_review_rework_requests_for_test(state)

    refute_receive {:memory_tracker_state_update, "issue-review-rework-approved", _state}, 200

    refute_receive {:memory_tracker_comment, "issue-review-rework-approved", "Symphony detected GitHub changes requested" <> _comment},
                   200

    refute_receive {:agent_runner_called, %{id: "issue-review-rework-approved"}, _opts}, 200
    assert updated_state.review_rework_rounds == %{}
    assert updated_state.running == %{}
  end

  test "review rework opt-in checks PR status at most once per interval" do
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

    review_rework_interval_ms = 60_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      poll_interval_ms: 50,
      review_rework_enabled: true,
      review_rework_interval_ms: review_rework_interval_ms
    )

    Application.put_env(:symphony_elixir, :github_review_status, FakeGitHubReviewCountingApproved)
    Application.put_env(:symphony_elixir, :github_review_status_recipient, self())

    pr_url = "https://github.com/acme/repo/pull/7701"

    issue = %Issue{
      id: "issue-review-rework-counting",
      identifier: "MT-REWORK-COUNTING",
      state: "In Review",
      attachment_urls: [pr_url]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{max_concurrent_agents: 10}
    checked_state = Orchestrator.reconcile_review_rework_requests_for_test(state)

    assert_receive {:github_review_status_view, ^pr_url}, 500
    assert is_integer(checked_state.last_review_rework_sync_ms)

    skipped_state = Orchestrator.reconcile_review_rework_requests_for_test(checked_state)

    refute_receive {:github_review_status_view, ^pr_url}, 200
    assert skipped_state.last_review_rework_sync_ms == checked_state.last_review_rework_sync_ms

    due_state = %{
      checked_state
      | last_review_rework_sync_ms: System.monotonic_time(:millisecond) - review_rework_interval_ms - 1
    }

    rechecked_state = Orchestrator.reconcile_review_rework_requests_for_test(due_state)

    assert_receive {:github_review_status_view, ^pr_url}, 500
    assert rechecked_state.last_review_rework_sync_ms >= due_state.last_review_rework_sync_ms
  end

  test "orchestrator does not duplicate blocked review recovery while review is pending" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_review_runner_recipient = Application.get_env(:symphony_elixir, :review_runner_recipient)
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

      if is_nil(previous_review_runner_recipient) do
        Application.delete_env(:symphony_elixir, :review_runner_recipient)
      else
        Application.put_env(:symphony_elixir, :review_runner_recipient, previous_review_runner_recipient)
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
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerSlowApproved)
    Application.put_env(:symphony_elixir, :review_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-blocked-review-handoff-pending"
    orchestrator_name = Module.concat(__MODULE__, :BlockedReviewHandoffPendingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BLOCKED-PENDING",
      branch_name: "aenima611111/generated-pending-branch",
      state: "In Progress"
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: "/tmp/mt-blocked-pending",
      session_id: "thread-blocked-pending",
      error: "issue moved to In Review without discoverable GitHub PR for branch aenima611111/generated-pending-branch or linked PR attachments; agent-owned PR is required before handoff",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    initial_state = :sys.get_state(pid, 15_000)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:blocked, %{issue_id => blocked_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))
    assert_receive :slow_review_started, 200

    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([issue], &1))
    refute_receive :slow_review_started, 100

    review_issue = %{issue | state: "In Review"}
    :sys.replace_state(pid, &Orchestrator.reconcile_blocked_issue_states_for_test([review_issue], &1))
    refute_receive :slow_review_started, 100

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000

    refute_receive {:tracker_comment_called, ^issue_id, _comment}, 100
    refute_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 100

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
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

    initial_state = :sys.get_state(pid, 15_000)

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

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "Merge judgment: ready for human final merge decision"
    assert comment =~ "The runtime will not approve on GitHub and will not merge automatically."

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "approved review handoff continues when evidence comment fails" do
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
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerCommentError)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-pr-comment-fails"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrCommentFailsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PR-COMMENT-FAILS",
      branch_name: "feature/pr-comment-fails",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-pr-comment-fails",
      session_id: "thread-pr-comment-fails",
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

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000

    state = :sys.get_state(pid, 15_000)
    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator snapshot remains responsive while review handoff is running" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    previous_lookup = Application.get_env(:symphony_elixir, :github_pr_lookup)
    previous_review_runner = Application.get_env(:symphony_elixir, :review_runner)
    previous_review_runner_recipient = Application.get_env(:symphony_elixir, :review_runner_recipient)
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

      if is_nil(previous_review_runner_recipient) do
        Application.delete_env(:symphony_elixir, :review_runner_recipient)
      else
        Application.put_env(:symphony_elixir, :review_runner_recipient, previous_review_runner_recipient)
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
    Application.put_env(:symphony_elixir, :review_runner, FakeReviewRunnerSlowApproved)
    Application.put_env(:symphony_elixir, :review_runner_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_module, FakeTrackerUpdateInReview)
    Application.put_env(:symphony_elixir, :tracker_state_update_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_comment_recipient, self())

    issue_id = "issue-normal-pr-slow-review"
    orchestrator_name = Module.concat(__MODULE__, :NormalPrSlowReviewOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()

    issue = %Issue{
      id: issue_id,
      identifier: "MT-SLOW-REVIEW",
      branch_name: "feature/slow-review",
      state: "In Progress"
    }

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/mt-slow-review",
      session_id: "thread-slow-review",
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

    assert_receive :slow_review_started, 200

    snapshot =
      Enum.reduce_while(1..20, :timeout, fn _attempt, _last_result ->
        case Orchestrator.snapshot(orchestrator_name, 500) do
          :timeout ->
            Process.sleep(25)
            {:cont, :timeout}

          snapshot ->
            {:halt, snapshot}
        end
      end)

    assert %{running: [], blocked: []} = snapshot
    refute_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 50

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000

    state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)

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

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "source: linked GitHub PR attachment"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000

    state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)

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
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "PR: https://github.example/pull/79"
    assert comment =~ "source: linked GitHub PR attachment"
    assert comment =~ "expected Linear branch: feature/linear-branch"
    assert comment =~ "actual PR branch: feature/actual-pr"

    state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 200
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "lib/example.ex:42 - Structured finding handled"
    assert comment =~ "mix test"
    assert comment =~ "none"

    assert MapSet.member?(state.completed, issue_id)
    assert state.blocked == %{}
  end

  test "orchestrator blocks review handoff when reviewer does not approve the PR" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      retry_max_review_handoff_attempts: 1
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

    initial_state = :sys.get_state(pid, 15_000)

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

    state =
      wait_for_orchestrator_state(pid, fn state ->
        error = get_in(state.blocked, [issue_id, :error])
        is_binary(error) and error =~ "review handoff retry limit reached (1)"
      end)

    refute_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 100
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 200
    assert comment =~ "review loop did not approve PR"

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{identifier: "MT-REVIEW-BLOCKED", error: error} = state.blocked[issue_id]
    assert error =~ "review handoff retry limit reached (1)"
    assert error =~ "review loop did not approve PR before In Review handoff: :review_blocked"
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

    initial_state = :sys.get_state(pid, 15_000)

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

    assert_receive {:tracker_state_update_called, ^issue_id, "Rework"}, 1_000
    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "review loop did not approve PR"

    state = :sys.get_state(pid, 15_000)
    refute Process.alive?(agent_pid)
    refute MapSet.member?(state.completed, issue_id)

    assert %{
             identifier: "MT-PREMATURE-REVIEW",
             issue: %Issue{state: "Rework"},
             error: error
           } = state.blocked[issue_id]

    assert error =~ "review handoff retry limit reached (3)"
    assert error =~ "review loop did not approve PR before In Review handoff: :review_blocked"
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

    initial_state = :sys.get_state(pid, 15_000)

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

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 1_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "Merge judgment: ready for human final merge decision"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 1_000

    state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)

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

    assert_receive {:tracker_comment_called, ^issue_id, comment}, 2_000
    assert comment =~ "Symphony automated review decision: approve-equivalent"
    assert comment =~ "source: linked GitHub PR attachment"
    assert_receive {:tracker_state_update_called, ^issue_id, "In Review"}, 2_000

    state = :sys.get_state(pid, 15_000)
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

    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)

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

    state =
      wait_for_orchestrator_state(pid, fn state ->
        error = get_in(state.blocked, [issue_id, :error])
        is_binary(error) and error =~ "handoff PR discovery retry limit reached"
      end)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{identifier: "MT-PR-ERROR", error: error} = state.blocked[issue_id]
    assert error =~ "handoff PR discovery retry limit reached (5)"
    assert error =~ "GitHub PR lookup failed for branch feature/pr-error: :missing_auth"
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
    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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
    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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

  test "orchestrator comments when workspace preparation quarantines dirty state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-dirty-workspace-quarantine"
    issue = %Issue{id: issue_id, identifier: "MT-DIRTY-QUARANTINE", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :DirtyWorkspaceQuarantineOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ref = make_ref()
    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-DIRTY-QUARANTINE",
      issue: issue,
      workspace_path: nil,
      session_id: "thread-dirty-workspace-quarantine",
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
      {:worker_runtime_info, issue_id,
       %{
         worker_host: nil,
         workspace_path: "/tmp/mt-dirty-fresh",
         workspace_quarantine: %{
           workspace: "/tmp/mt-dirty-fresh",
           quarantine: "/tmp/mt-dirty-fresh.dirty-20260617-010203",
           dirty_status: " M README.md\n?? docs/operations/LAB-269-smoke.md\n"
         }
       }}
    )

    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{workspace_path: "/tmp/mt-dirty-fresh"} = state.running[issue_id]
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked, issue_id)

    assert_receive {:memory_tracker_comment, ^issue_id, comment}
    assert comment =~ "Symphony quarantined a dirty workspace before rerunning MT-DIRTY-QUARANTINE"
    assert comment =~ "Workspace: /tmp/mt-dirty-fresh"
    assert comment =~ "Quarantine: /tmp/mt-dirty-fresh.dirty-20260617-010203"
    assert comment =~ "README.md"
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

    initial_state = :sys.get_state(pid, 15_000)

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
    state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)
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
    initial_state = :sys.get_state(pid, 15_000)

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

    initial_state = :sys.get_state(pid, 15_000)

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

  test "status dashboard renders unroutable issue routing reasons" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         unroutable: [
           %{
             issue_id: "issue-route",
             identifier: "LAB-474",
             project_name: "auto_template",
             reason: "missing_project_route",
             message: "Linear project is not mapped to a repository"
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "Routing attention"
    assert plain =~ "LAB-474"
    assert plain =~ "project=auto_template"
    assert plain =~ "Linear project is not mapped to a repository"
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

    assert {:ok, stderr_config} = :logger.get_handler_config(:symphony_stderr_log)
    assert stderr_config.module == :logger_std_h
    assert stderr_config.level == :warning
    assert stderr_config.config.type == :standard_error
  end

  test "status dashboard is disabled without a terminal unless explicitly enabled" do
    refute StatusDashboard.dashboard_enabled_for_test()

    refute StatusDashboard.dashboard_enabled_for_test(
             tty_check: fn -> false end,
             mix_env_check: fn -> true end
           )

    assert StatusDashboard.dashboard_enabled_for_test(
             tty_check: fn -> true end,
             mix_env_check: fn -> true end
           )

    dashboard_name = Module.concat(__MODULE__, :NoTtyDashboard)
    parent = self()

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    refute_receive {:render, _content}, 100
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(
        %{
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
        },
        140
      )

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

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
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-898",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: payload
        },
        140
      )

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

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 2_000) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp assert_tracker_comment_contains(issue_id, expected, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_tracker_comment_contains(issue_id, expected, deadline_ms)
  end

  defp do_assert_tracker_comment_contains(issue_id, expected, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:tracker_comment_called, ^issue_id, comment} ->
        if comment =~ expected do
          comment
        else
          do_assert_tracker_comment_contains(issue_id, expected, deadline_ms)
        end
    after
      remaining_ms ->
        flunk("timed out waiting for tracker comment #{inspect(expected)} on #{issue_id}")
    end
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state =
      try do
        :sys.get_state(pid, 1_000)
      catch
        :exit, _reason -> nil
      end

    if state != nil and predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")
      else
        Process.sleep(10)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
      end
    end
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot, 15_000)

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
