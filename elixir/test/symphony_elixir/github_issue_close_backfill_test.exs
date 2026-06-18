defmodule SymphonyElixir.GitHubIssueCloseBackfillTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubIssueCloseBackfill
  alias SymphonyElixir.Linear.Issue

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(Process.get(:test_pid), {:fetch_issues_by_states, states})

      {:ok,
       [
         %Issue{
           id: "issue-1",
           identifier: "LAB-1",
           title: "Done issue with open source",
           description: "GitHub Issue: https://github.com/octo/repo/issues/1",
           url: "https://linear.app/test/issue/LAB-1"
         },
         %Issue{
           id: "issue-2",
           identifier: "LAB-2",
           title: "Done issue with closed source",
           description: "GitHub Issue: https://github.com/octo/repo/issues/2",
           url: "https://linear.app/test/issue/LAB-2"
         },
         %Issue{
           id: "issue-3",
           identifier: "LAB-3",
           title: "Different repo",
           description: "GitHub Issue: https://github.com/acme/other/issues/3",
           url: "https://linear.app/test/issue/LAB-3"
         },
         %Issue{
           id: "issue-4",
           identifier: "LAB-4",
           title: "No source issue",
           description: "No GitHub issue here",
           url: "https://linear.app/test/issue/LAB-4"
         }
       ]}
    end
  end

  defmodule FakeScopedLinearClient do
    def fetch_issues_by_states(_states), do: {:error, :unexpected_unscoped_fetch}

    def fetch_issues_by_states(states, opts) do
      send(Process.get(:test_pid), {:fetch_issues_by_states, states, opts})
      {:ok, []}
    end
  end

  defmodule FakeGitHubIssue do
    def closed_at(repo, url) do
      send(Process.get(:test_pid), {:closed_at, repo, url})

      case url do
        "https://github.com/octo/repo/issues/1" -> {:ok, nil}
        "https://github.com/octo/repo/issues/2" -> {:ok, "2026-06-18T00:00:00Z"}
      end
    end

    def close_if_open(repo, url, comment) do
      send(Process.get(:test_pid), {:close_if_open, repo, url, comment})
      {:ok, :closed}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "dry-run reports open GitHub source issues without closing them" do
    assert {:ok, summary} =
             GitHubIssueCloseBackfill.run(
               repo: "octo/repo",
               linear_client: FakeLinearClient,
               github_issue: FakeGitHubIssue
             )

    assert_receive {:fetch_issues_by_states, ["Done"]}
    assert_receive {:closed_at, "octo/repo", "https://github.com/octo/repo/issues/1"}
    assert_receive {:closed_at, "octo/repo", "https://github.com/octo/repo/issues/2"}
    refute_received {:close_if_open, _, _, _}

    assert summary.inspected == 4
    assert summary.candidates == 1
    assert summary.closed == 0
    assert summary.already_closed == 1
    assert summary.skipped == 2
    assert summary.errors == []
    assert [%{issue: "LAB-1", status: :would_close}, %{issue: "LAB-2", status: :already_closed}] = summary.actions
  end

  test "execute closes open GitHub source issues" do
    assert {:ok, summary} =
             GitHubIssueCloseBackfill.run(
               repo: "octo/repo",
               execute: true,
               linear_client: FakeLinearClient,
               github_issue: FakeGitHubIssue
             )

    assert_receive {:close_if_open, "octo/repo", "https://github.com/octo/repo/issues/1", comment}
    assert comment =~ "LAB-1"
    assert comment =~ "https://linear.app/test/issue/LAB-1"

    assert summary.candidates == 1
    assert summary.closed == 1
    assert summary.already_closed == 1
    assert summary.errors == []
    assert [%{issue: "LAB-1", status: :closed}, %{issue: "LAB-2", status: :already_closed}] = summary.actions
  end

  test "passes explicit Linear scope options when supported by the client" do
    assert {:ok, summary} =
             GitHubIssueCloseBackfill.run(
               repo: "octo/repo",
               team_key: "LAB",
               all_projects: true,
               linear_client: FakeScopedLinearClient,
               github_issue: FakeGitHubIssue
             )

    assert_receive {:fetch_issues_by_states, ["Done"], opts}
    assert opts[:team_key] == "LAB"
    assert opts[:all_projects] == true
    assert summary.inspected == 0
  end
end
