defmodule SymphonyElixir.LandingWorkerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LandingWorker

  defmodule FakeTracker do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    def add_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_labels, issue_id, labels})
      :ok
    end

    def remove_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_remove_labels, issue_id, labels})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerNoState do
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerRemoveLabelsError do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    def remove_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_remove_labels, issue_id, labels})
      {:error, :label_cleanup_down}
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerRemoveLabelsOkTuple do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    def remove_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_remove_labels, issue_id, labels})
      {:ok, :removed}
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerRemoveLabelsUnexpected do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    def remove_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_remove_labels, issue_id, labels})
      :unexpected
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerNoComment do
    def update_issue_state(_issue_id, _state_name), do: :ok
  end

  defmodule FakeTrackerStateError do
    def update_issue_state(_issue_id, _state_name), do: {:error, :linear_down}

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerBlockedStateMissing do
    def update_issue_state(issue_id, "Blocked") do
      send(test_pid(), {:landing_state_update, issue_id, "Blocked"})
      {:error, :state_not_found}
    end

    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    def add_issue_labels(issue_id, labels) do
      send(test_pid(), {:landing_labels, issue_id, labels})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerCommentError do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(_issue_id, _body), do: {:error, :comment_down}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerSecondCommentError do
    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      count = Process.get(:landing_comment_count, 0) + 1
      Process.put(:landing_comment_count, count)
      send(test_pid(), {:landing_comment, issue_id, body})

      if count == 1, do: :ok, else: {:error, :comment_down}
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  defmodule FakeTrackerDoneStateError do
    def update_issue_state(issue_id, "Done") do
      send(test_pid(), {:landing_state_update, issue_id, "Done"})
      {:error, :done_state_down}
    end

    def update_issue_state(issue_id, state_name) do
      send(test_pid(), {:landing_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(test_pid(), {:landing_comment, issue_id, body})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :landing_worker_test_pid)
  end

  setup do
    Application.put_env(:symphony_elixir, :landing_worker_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :landing_worker_test_pid)
    end)

    :ok
  end

  test "does nothing while execution is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: false
    )

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry()], deps())

    assert result == %{
             enabled: false,
             attempted: 0,
             merged: 0,
             blocked: 0,
             repair_requested: 0,
             skipped: 0,
             errors: 0
           }

    refute_receive {:landing_state_update, _issue_id, _state_name}, 100
    refute_receive {:landing_comment, _issue_id, _body}, 100
  end

  test "does nothing while landing is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: false,
      landing_execute_enabled: true
    )

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry()])

    assert result == %{
             enabled: false,
             attempted: 0,
             merged: 0,
             blocked: 0,
             repair_requested: 0,
             skipped: 0,
             errors: 0
           }

    refute_receive {:gh_command, _args}, 100
  end

  test "treats invalid queue payloads as empty or skipped" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 0, skipped: 0, errors: 0} =
             LandingWorker.execute(Config.settings!(), FakeTracker, :not_a_list, deps())

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 0, skipped: 1, errors: 0} =
             LandingWorker.execute(Config.settings!(), FakeTracker, [:not_a_map], deps())
  end

  test "reports tracker capability errors before execution" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 0, skipped: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerNoState, [ready_entry()], deps())

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 0, skipped: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerNoComment, [ready_entry()], deps())
  end

  test "revalidates and merges the first ready queue entry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_merge_method: "squash",
      landing_max_per_run: 1
    )

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry(), ready_entry("issue-2", "LAB-2", "https://github.com/octo/repo/pull/2")], deps())

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert start_body =~ "merge with squash"
    assert_receive {:gh_command, ["pr", "view", "https://github.com/octo/repo/pull/1", "--json", _json]}
    assert_receive {:gh_command, ["pr", "merge", "https://github.com/octo/repo/pull/1", "--squash"]}
    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_remove_labels, "issue-1", labels}
    assert "landing-blocked" in labels
    assert "landing-conflict" in labels
    assert "landing-checks-failing" in labels
    assert "landing-needs-review" in labels
    assert "landing-draft" in labels
    assert "landing-stale-pr" in labels
    assert_receive {:landing_comment, "issue-1", success_body}
    assert success_body =~ "execution completed"
    assert success_body =~ "Linear state: moved to Done"
    assert success_body =~ "Labels: removed landing blocking labels"
    refute_receive {:landing_state_update, "issue-2", _state_name}, 100
  end

  test "revalidates queue entries with unknown draft state before merging" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    result =
      LandingWorker.execute(
        Config.settings!(),
        FakeTracker,
        [%{ready_entry() | draft: "unknown"}],
        deps()
      )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 0} = result
    assert_receive {:gh_command, ["pr", "view", "https://github.com/octo/repo/pull/1", "--json", _json]}
    assert_receive {:gh_command, ["pr", "merge", "https://github.com/octo/repo/pull/1", "--squash"]}
    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_state_update, "issue-1", "Done"}
  end

  test "blocks stale PRs without merging" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_blocked_state: "Needs Human"
    )

    result =
      LandingWorker.execute(
        Config.settings!(),
        FakeTracker,
        [ready_entry()],
        deps(%{"https://github.com/octo/repo/pull/1" => pr_view(%{"mergeStateStatus" => "DIRTY"})})
      )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Needs Human"}
    assert_receive {:landing_labels, "issue-1", labels}
    assert "landing-blocked" in labels
    assert "landing-conflict" in labels
    assert_receive {:landing_comment, "issue-1", body}
    assert body =~ "execution blocked"
    assert body =~ "PR mergeability changed to DIRTY"
    assert body =~ "Labels: landing-blocked, landing-conflict"
    refute_receive {:landing_state_update, "issue-1", "In Progress"}, 100
    refute_receive {:gh_command, ["pr", "merge" | _args]}, 100
  end

  test "requests repair after blocking stale PRs when enabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_blocked_state: "Blocked",
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    result =
      LandingWorker.execute(
        Config.settings!(),
        FakeTracker,
        [ready_entry()],
        deps(%{"https://github.com/octo/repo/pull/1" => pr_view(%{"mergeStateStatus" => "DIRTY"})})
      )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, repair_requested: 1, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_comment, "issue-1", blocked_body}
    assert blocked_body =~ "PR mergeability changed to DIRTY"
    assert_receive {:landing_state_update, "issue-1", "In Progress"}
    assert_receive {:landing_comment, "issue-1", repair_body}
    assert repair_body =~ "repair requested"
    assert repair_body =~ "https://github.com/octo/repo/pull/1"
    assert repair_body =~ "PR mergeability changed to DIRTY"
    assert repair_body =~ "In Review"
    assert repair_body =~ "Approved to Land"
    assert repair_body =~ "must not merge"
    refute_receive {:gh_command, ["pr", "merge" | _args]}, 100
  end

  test "blocks PRs that become closed, draft, changes requested, or retargeted" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    cases = [
      {%{"state" => "CLOSED"}, "PR is no longer open: CLOSED"},
      {%{"isDraft" => true}, "PR is draft"},
      {%{"reviewDecision" => "CHANGES_REQUESTED"}, "GitHub review decision is CHANGES_REQUESTED"},
      {%{"headRefName" => "different-branch"}, "PR head branch changed from lab-1 to different-branch"},
      {%{"headRefOid" => "def456"}, "PR head SHA changed from abc123 to def456"}
    ]

    for {pr_overrides, expected_reason} <- cases do
      result =
        LandingWorker.execute(
          Config.settings!(),
          FakeTracker,
          [ready_entry()],
          deps(%{"https://github.com/octo/repo/pull/1" => pr_view(pr_overrides)})
        )

      assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 0} = result
      assert_receive {:landing_state_update, "issue-1", "Blocked"}
      assert_receive {:landing_comment, "issue-1", body}
      assert body =~ expected_reason
      refute_receive {:gh_command, ["pr", "merge" | _args]}, 50
    end
  end

  test "reports gh lookup and JSON failures as execution errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry()], deps(%{}, gh_bin: nil))

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTracker,
               [ready_entry()],
               deps(%{"https://github.com/octo/repo/pull/1" => {"not-json", 0}})
             )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTracker,
               [ready_entry()],
               deps(%{"https://github.com/octo/repo/pull/1" => {"not found", 1}})
             )
  end

  test "blocks merge command failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    result =
      LandingWorker.execute(
        Config.settings!(),
        FakeTracker,
        [ready_entry()],
        deps(%{}, merge_result: {"merge blocked by protection", 1})
      )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_comment, "issue-1", blocked_body}
    assert blocked_body =~ "GitHub merge command failed with status 1"
  end

  test "requests repair after merge command blockers when enabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_repair_enabled: true,
      landing_repair_state: "In Progress"
    )

    result =
      LandingWorker.execute(
        Config.settings!(),
        FakeTracker,
        [ready_entry()],
        deps(%{}, merge_result: {"merge conflict", 1})
      )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, repair_requested: 1, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_comment, "issue-1", blocked_body}
    assert blocked_body =~ "GitHub merge command failed with status 1"
    assert_receive {:landing_state_update, "issue-1", "In Progress"}
    assert_receive {:landing_comment, "issue-1", repair_body}
    assert repair_body =~ "merge conflict"
    assert repair_body =~ "normal implementation agent"
  end

  test "supports configured merge methods" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_merge_method: "rebase"
    )

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry()], deps())

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 0} = result
    assert_receive {:gh_command, ["pr", "merge", "https://github.com/octo/repo/pull/1", "--rebase"]}

    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true,
      landing_merge_method: "merge"
    )

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [ready_entry()], deps())

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 0} = result
    assert_receive {:gh_command, ["pr", "merge", "https://github.com/octo/repo/pull/1", "--merge"]}
  end

  test "reports Linear write failures as execution errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerStateError, [ready_entry()], deps())

    assert_receive {:landing_comment, "issue-1", transition_body}
    assert transition_body =~ "execution could not start"
    assert transition_body =~ "Target state: Landing"
    assert transition_body =~ "No merge was attempted"

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerCommentError, [ready_entry()], deps())

    assert_receive {:gh_command, ["pr", "view", "https://github.com/octo/repo/pull/1", "--json", _json]}
  end

  test "comments visibly when the configured blocked state is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTrackerBlockedStateMissing,
               [ready_entry()],
               deps(%{"https://github.com/octo/repo/pull/1" => pr_view(%{"mergeStateStatus" => "DIRTY"})})
             )

    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_labels, "issue-1", labels}
    assert labels == ["landing-blocked", "landing-conflict"]
    assert_receive {:landing_comment, "issue-1", body}
    assert body =~ "could not mark the item blocked"
    assert body =~ "Original blocker: PR mergeability changed to DIRTY"
    assert body =~ "Target blocked state: Blocked"
    assert body =~ "state_not_found"
    assert body =~ "Labels: landing-blocked, landing-conflict"
    refute_receive {:gh_command, ["pr", "merge" | _args]}, 100
  end

  test "moves Landing items to Blocked when start comments or merge commands error after state transition" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerCommentError, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_state_update, "issue-1", "Blocked"}

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 0} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTracker,
               [ready_entry()],
               deps(%{}, merge_result: {:error, :timeout})
             )

    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_comment, "issue-1", blocked_body}
    assert blocked_body =~ "Landing execution failed before merge completion"
  end

  test "counts merged PRs even when success comment fails after merge" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerSecondCommentError, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_comment, "issue-1", success_body}
    assert success_body =~ "execution completed"
  end

  test "counts merged PRs and reports cleanup failures after Done verification" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerRemoveLabelsError, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_remove_labels, "issue-1", labels}
    assert "landing-blocked" in labels
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_comment, "issue-1", success_body}
    assert success_body =~ "execution completed"
    assert success_body =~ "Labels: cleanup failed: :label_cleanup_down"
  end

  test "accepts successful cleanup tuples after Done verification" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 0} =
             LandingWorker.execute(Config.settings!(), FakeTrackerRemoveLabelsOkTuple, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_remove_labels, "issue-1", labels}
    assert "landing-blocked" in labels
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_comment, "issue-1", success_body}
    assert success_body =~ "Labels: removed landing blocking labels"
  end

  test "counts merged PRs and reports unexpected cleanup results after Done verification" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 0, errors: 1} =
             LandingWorker.execute(Config.settings!(), FakeTrackerRemoveLabelsUnexpected, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_remove_labels, "issue-1", labels}
    assert "landing-blocked" in labels
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:landing_comment, "issue-1", success_body}
    assert success_body =~ "Labels: cleanup failed: {:linear_label_cleanup_unexpected, :unexpected}"
  end

  test "blocks merged PRs when Done transition verification fails after merge" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 1, blocked: 1, errors: 0} =
             LandingWorker.execute(Config.settings!(), FakeTrackerDoneStateError, [ready_entry()], deps())

    assert_receive {:landing_state_update, "issue-1", "Landing"}
    assert_receive {:landing_comment, "issue-1", start_body}
    assert start_body =~ "execution started"
    assert_receive {:gh_command, ["pr", "merge", "https://github.com/octo/repo/pull/1", "--squash"]}
    assert_receive {:landing_state_update, "issue-1", "Done"}
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_comment, "issue-1", blocker_body}
    assert blocker_body =~ "execution needs attention after merge"
    assert blocker_body =~ "PR merged but Linear Done verification failed"
    assert blocker_body =~ "moved to Blocked for manual reconciliation"
    refute blocker_body =~ "execution completed"
  end

  test "moves blocked skip entries to Blocked with labels and a visible reason" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    entry = %{ready_entry() | mergeability: "DIRTY", status: "blocked", planned_action: "skip", blocker: "conflict"}

    result = LandingWorker.execute(Config.settings!(), FakeTracker, [entry], deps())

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 1, skipped: 0, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_labels, "issue-1", labels}
    assert labels == ["landing-blocked", "landing-conflict"]
    assert_receive {:landing_comment, "issue-1", body}
    assert body =~ "execution blocked"
    assert body =~ "Reason: conflict"
    assert body =~ "Labels: landing-blocked, landing-conflict"
    refute_receive {:gh_command, _args}, 100
  end

  test "blocks draft and malformed ready entries before gh revalidation when an issue id is available" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    entries = [
      %{ready_entry() | draft: true},
      %{ready_entry("issue-2", "LAB-2", "https://github.com/octo/repo/pull/2") | draft: "true"},
      %{ready_entry("issue-3", "LAB-3", "not-a-pr-url") | draft: false},
      %{ready_entry(nil, "LAB-4", "https://github.com/octo/repo/pull/4") | draft: false}
    ]

    result = LandingWorker.execute(Config.settings!(), FakeTracker, entries, deps())

    assert %{enabled: true, attempted: 0, merged: 0, blocked: 3, skipped: 1, errors: 0} = result
    assert_receive {:landing_state_update, "issue-1", "Blocked"}
    assert_receive {:landing_labels, "issue-1", labels}
    assert "landing-draft" in labels
    assert_receive {:landing_comment, "issue-1", body}
    assert body =~ "PR is draft"

    assert_receive {:landing_state_update, "issue-2", "Blocked"}
    assert_receive {:landing_labels, "issue-2", labels}
    assert "landing-draft" in labels

    assert_receive {:landing_state_update, "issue-3", "Blocked"}
    assert_receive {:landing_labels, "issue-3", labels}
    assert labels == ["landing-blocked"]
    assert_receive {:landing_comment, "issue-3", body}
    assert body =~ "PR URL is missing or invalid"

    refute_receive {:gh_command, _args}, 100
  end

  test "reports command error tuples and block write failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      landing_enabled: true,
      landing_execute_enabled: true
    )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTracker,
               [ready_entry()],
               deps(%{"https://github.com/octo/repo/pull/1" => {:error, :timeout}})
             )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 1, errors: 0} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTracker,
               [ready_entry()],
               deps(%{}, merge_result: {:error, :timeout})
             )

    assert %{enabled: true, attempted: 1, merged: 0, blocked: 0, errors: 1} =
             LandingWorker.execute(
               Config.settings!(),
               FakeTrackerStateError,
               [ready_entry()],
               deps(%{"https://github.com/octo/repo/pull/1" => pr_view(%{"mergeStateStatus" => "DIRTY"})})
             )
  end

  defp ready_entry(issue_id \\ "issue-1", issue_identifier \\ "LAB-1", pr_url \\ "https://github.com/octo/repo/pull/1") do
    %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      queue_position: 1,
      queue_total: 1,
      planned_action: "merge",
      status: "ready",
      blocker: "none",
      pr_url: pr_url,
      pr_state: "OPEN",
      draft: "false",
      mergeability: "CLEAN",
      head_branch: "lab-1",
      head_sha: "abc123"
    }
  end

  defp deps(pr_views \\ %{}, opts \\ []) do
    parent = self()
    merge_result = Keyword.get(opts, :merge_result, {"Merged", 0})
    gh_bin = Keyword.get(opts, :gh_bin, "gh")

    %{
      find_gh_bin: fn -> gh_bin end,
      run_command: fn "gh", args, _opts ->
        send(parent, {:gh_command, args})

        case args do
          ["pr", "view", pr_url, "--json", _json] ->
            Map.get(pr_views, pr_url, pr_view())

          ["pr", "merge", _pr_url, _merge_method] ->
            merge_result
        end
      end
    }
  end

  defp pr_view(overrides \\ %{}) do
    %{
      "number" => 1,
      "url" => "https://github.com/octo/repo/pull/1",
      "state" => "OPEN",
      "isDraft" => false,
      "mergeStateStatus" => "CLEAN",
      "headRefName" => "lab-1",
      "headRefOid" => "abc123",
      "baseRefName" => "main",
      "reviewDecision" => "APPROVED"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
    |> then(&{&1, 0})
  end
end
