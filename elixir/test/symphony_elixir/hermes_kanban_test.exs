defmodule SymphonyElixir.HermesKanbanTest do
  use SymphonyElixir.TestSupport

  describe "sync_issue_running/2" do
    test "creates or returns a Hermes Kanban task through the official CLI" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes",
        hermes_kanban_board: "default",
        hermes_kanban_tenant: "auto_template",
        hermes_kanban_assignee: "symphony"
      )

      issue = %Issue{
        id: "linear-issue-1",
        identifier: "LAB-280",
        title: "Sync Linear issue",
        description: "Mirror me",
        state: "In Progress",
        url: "https://linear.app/issue/LAB-280"
      }

      cmd = fn command, args, _opts ->
        send(self(), {:cmd, command, args})
        {~s({"id":"task-123"}), 0}
      end

      assert {:ok, "task-123"} = SymphonyElixir.HermesKanban.sync_issue_running(issue, cmd: cmd)

      assert_receive {:cmd, "/opt/hermes/bin/hermes", args}

      assert args == [
               "kanban",
               "--board",
               "default",
               "create",
               "LAB-280 Sync Linear issue",
               "--idempotency-key",
               "linear:linear-issue-1",
               "--body",
               "Linear: https://linear.app/issue/LAB-280\n\nMirror me",
               "--initial-status",
               "running",
               "--tenant",
               "auto_template",
               "--assignee",
               "symphony",
               "--json"
             ]
    end

    test "does nothing when Hermes Kanban sync is disabled" do
      cmd = fn _command, _args, _opts ->
        flunk("disabled Hermes sync must not invoke the CLI")
      end

      assert :ok = SymphonyElixir.HermesKanban.sync_issue_running(%Issue{id: "issue-1"}, cmd: cmd)
    end

    test "returns an error without raising when the CLI exits non-zero" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes"
      )

      cmd = fn _command, _args, _opts -> {"boom", 1} end

      assert {:error, {:command_failed, 1, "boom"}} =
               SymphonyElixir.HermesKanban.sync_issue_running(%Issue{id: "issue-1"}, cmd: cmd)
    end

    test "returns an error when the CLI emits invalid JSON" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes"
      )

      cmd = fn _command, _args, _opts -> {"<html>error</html>", 0} end

      assert {:error, {:invalid_json, _message, "<html>error</html>"}} =
               SymphonyElixir.HermesKanban.sync_issue_running(%Issue{id: "issue-1"}, cmd: cmd)
    end

    test "returns an error when the create payload does not include a task id" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes"
      )

      cmd = fn _command, _args, _opts -> {~s({"ok":true}), 0} end

      assert {:error, {:missing_task_id, %{"ok" => true}}} =
               SymphonyElixir.HermesKanban.sync_issue_running(%Issue{id: "issue-1"}, cmd: cmd)
    end
  end

  describe "sync_issue_done/2" do
    test "completes a known Hermes task id with structured metadata" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes",
        hermes_kanban_tenant: "auto_template"
      )

      issue = %Issue{
        id: "linear-issue-2",
        identifier: "LAB-281",
        title: "Complete Linear issue",
        description: "Done body",
        url: "https://linear.app/issue/LAB-281"
      }

      cmd = fn command, args, _opts ->
        send(self(), {:cmd, command, args})
        {"{}", 0}
      end

      assert {:ok, "task-456"} =
               SymphonyElixir.HermesKanban.sync_issue_done(issue,
                 task_id: "task-456",
                 summary: "Symphony handed off LAB-281 to review",
                 metadata: %{
                   "linear_identifier" => "wrong",
                   "linear_url" => "wrong",
                   "pr_url" => "https://github.example/pr/1",
                   "source" => "wrong"
                 },
                 cmd: cmd
               )

      assert_receive {:cmd, "/opt/hermes/bin/hermes", complete_args}

      refute "create" in complete_args

      assert complete_args == [
               "kanban",
               "--board",
               "default",
               "complete",
               "task-456",
               "--summary",
               "Symphony handed off LAB-281 to review",
               "--metadata",
               ~s({"linear_identifier":"LAB-281","linear_url":"https://linear.app/issue/LAB-281","pr_url":"https://github.example/pr/1","source":"symphony"})
             ]
    end

    test "does not call the CLI when no Hermes task id is available" do
      write_workflow_file!(Workflow.workflow_file_path(),
        hermes_kanban_enabled: true,
        hermes_kanban_command: "/opt/hermes/bin/hermes"
      )

      cmd = fn _command, _args, _opts ->
        flunk("done sync without a task id must not create or complete a task")
      end

      assert {:error, :missing_task_id} =
               SymphonyElixir.HermesKanban.sync_issue_done(%Issue{id: "issue-1"}, cmd: cmd)
    end
  end
end
