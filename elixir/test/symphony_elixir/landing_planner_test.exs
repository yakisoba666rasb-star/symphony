defmodule SymphonyElixir.LandingPlannerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LandingPlanner

  defmodule FakeTracker do
    def fetch_issues_by_states(states) do
      send(test_pid(), {:landing_fetch_states, states})
      {:ok, Application.get_env(:symphony_elixir, :landing_planner_issues, [])}
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :test_pid)
  end

  defmodule FakePrLookup do
    def lookup_open_issue_pull_request(repo, issue_identifier, issue_url, branch_name, attachment_urls) do
      send(test_pid(), {:landing_pr_lookup, repo, issue_identifier, issue_url, branch_name, attachment_urls})

      {:ok,
       %{
         "number" => 42,
         "url" => "https://github.com/octo/repo/pull/42",
         "headRefName" => branch_name || "lab-500",
         "isDraft" => false,
         "mergeStateStatus" => "CLEAN",
         "headRefOid" => "abc123",
         "state" => "OPEN"
       }}
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :test_pid)
  end

  defmodule FakePrLookupNone do
    def lookup_open_issue_pull_request(_repo, _issue_identifier, _issue_url, _branch_name, _attachment_urls) do
      {:ok, nil}
    end
  end

  defmodule FakeTrackerFetchError do
    def fetch_issues_by_states(_states), do: {:error, :linear_down}
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerCommentVariants do
    def fetch_issues_by_states(_states) do
      {:ok, Application.get_env(:symphony_elixir, :landing_planner_issues, [])}
    end

    def create_comment("issue-ok-tuple", _body), do: {:ok, %{id: "comment-1"}}
    def create_comment("issue-error", _body), do: {:error, :comment_denied}
    def create_comment("issue-weird", _body), do: :unexpected
  end

  defmodule FakeTrackerNoFetch do
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerNoComment do
    def fetch_issues_by_states(_states), do: {:ok, []}
  end

  defmodule FakePrLookupMissing do
  end

  setup do
    Application.put_env(:symphony_elixir, :test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :test_pid)
      Application.delete_env(:symphony_elixir, :landing_planner_issues)
    end)
  end

  test "creates a dry-run plan comment for approved landing issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    issue = %Issue{
      id: "issue-500",
      identifier: "LAB-500",
      title: "Ship landing MVP",
      state: "Approved to Land",
      branch_name: "lab-500",
      url: "https://linear.app/example/issue/LAB-500"
    }

    Application.put_env(:symphony_elixir, :landing_planner_issues, [issue])

    assert %{inspected: 1, commented: 1, skipped: 0, errors: 0, queue: [queue_entry]} =
             LandingPlanner.reconcile(Config.settings!(), FakeTracker, FakePrLookup)

    assert queue_entry.queue_position == 1
    assert queue_entry.queue_total == 1
    assert queue_entry.planned_action == "merge"
    assert queue_entry.repository == "octo/repo"
    assert queue_entry.mergeability == "CLEAN"
    assert queue_entry.head_sha == "abc123"
    assert queue_entry.blocker == "none"

    assert_receive {:landing_fetch_states, ["Approved to Land"]}

    assert_receive {:landing_pr_lookup, "octo/repo", "LAB-500", "https://linear.app/example/issue/LAB-500", "lab-500", []}

    assert_receive {:landing_comment, "issue-500", body}
    assert body =~ LandingPlanner.marker()
    assert body =~ "Symphony Approved to Land dry-run plan"
    assert body =~ "Planned action: merge (execution gated)"
    assert body =~ "PR: https://github.com/octo/repo/pull/42"
    assert body =~ "mergeability: CLEAN"
    assert body =~ "head SHA: abc123"
  end

  test "does not create duplicate dry-run comments when marker already exists" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    issue = %Issue{
      id: "issue-501",
      identifier: "LAB-501",
      title: "Already planned",
      state: "Approved to Land",
      comments: [%{"body" => "#{LandingPlanner.marker()} issue_id=issue-501 -->"}]
    }

    Application.put_env(:symphony_elixir, :landing_planner_issues, [issue])

    assert %{inspected: 1, commented: 0, skipped: 1, errors: 0} =
             LandingPlanner.reconcile(Config.settings!(), FakeTracker, FakePrLookup)

    refute_receive {:landing_comment, "issue-501", _body}, 100
  end

  test "comments a skip plan when no open PR is found" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    issue = %Issue{
      id: "issue-502",
      identifier: "LAB-502",
      title: "Missing PR",
      state: "Approved to Land"
    }

    Application.put_env(:symphony_elixir, :landing_planner_issues, [issue])

    assert %{inspected: 1, commented: 1, skipped: 0, errors: 0} =
             LandingPlanner.reconcile(Config.settings!(), FakeTracker, FakePrLookupNone)

    assert_receive {:landing_comment, "issue-502", body}
    assert body =~ "Planned action: skip (execution gated)"
    assert body =~ "blocker: no open GitHub PR found"
  end

  test "does nothing when landing is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: false,
      repository_default: "octo/repo"
    )

    assert %{inspected: 0, commented: 0, skipped: 0, errors: 0} =
             LandingPlanner.reconcile(Config.settings!(), FakeTracker, FakePrLookup)

    refute_receive {:landing_fetch_states, _states}, 100
  end

  test "skips when tracker does not expose required landing functions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    assert %{inspected: 0, commented: 0, skipped: 0, errors: 0} =
             LandingPlanner.reconcile(Config.settings!(), FakeTrackerNoFetch, FakePrLookup)

    assert %{inspected: 0, commented: 0, skipped: 0, errors: 0} =
             LandingPlanner.reconcile(Config.settings!(), FakeTrackerNoComment, FakePrLookup)
  end

  test "reports fetch and comment errors without mutating issue state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    assert %{inspected: 0, commented: 0, skipped: 0, errors: 1} =
             LandingPlanner.reconcile(Config.settings!(), FakeTrackerFetchError, FakePrLookup)

    Application.put_env(:symphony_elixir, :landing_planner_issues, [
      %Issue{id: "issue-ok-tuple", identifier: "LAB-503"},
      %Issue{id: "issue-error", identifier: "LAB-504"},
      %Issue{id: "issue-weird", identifier: "LAB-505"}
    ])

    assert %{inspected: 3, commented: 1, skipped: 0, errors: 2} =
             LandingPlanner.reconcile(Config.settings!(), FakeTrackerCommentVariants, FakePrLookup)
  end

  test "handles unroutable issues, invalid issue ids, non-issues, and missing PR lookup support" do
    write_workflow_file!(Workflow.workflow_file_path(), landing_enabled: true)

    Application.put_env(:symphony_elixir, :landing_planner_issues, [
      %Issue{id: "issue-unroutable", identifier: "LAB-506"},
      %Issue{id: "", identifier: "LAB-507"},
      %{id: "not-an-issue"}
    ])

    assert %{inspected: 2, commented: 1, skipped: 1, errors: 1} =
             LandingPlanner.reconcile(Config.settings!(), FakeTracker, FakePrLookupMissing)

    assert_receive {:landing_comment, "issue-unroutable", body}
    assert body =~ "Planned action: skip (execution gated)"
    assert body =~ "blocker: repository resolver returned invalid result"
  end

  test "plan comments render ready validation snapshots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      repository_default: "octo/repo"
    )

    issue = %Issue{id: "issue-atom", identifier: "LAB-508"}

    snapshot = %{
      status: :ready,
      repository: "octo/repo",
      pr_url: "https://github.com/octo/repo/pull/50",
      pr_state: "OPEN",
      draft: "false",
      mergeability: "CLEAN",
      head_branch: "lab-508",
      head_sha: "def456",
      blocker: "none"
    }

    body = LandingPlanner.plan_comment(issue, 1, 1, "plan-1", snapshot, Config.settings!())

    assert body =~ "Planned action: merge (execution gated)"
    assert body =~ "PR state: OPEN"
    assert body =~ "head branch: lab-508"
    assert body =~ "head SHA: def456"
  end
end
