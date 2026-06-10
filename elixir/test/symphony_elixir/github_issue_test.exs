defmodule SymphonyElixir.GitHubIssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubIssue

  test "closes open source issue in the matching repository" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        send(parent, {:command, args})

        case args do
          ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"] ->
            {:ok, {Jason.encode!(%{"state" => "OPEN"}), 0}}

          ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"] ->
            {:ok, {"closed\n", 0}}
        end
      end
    }

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )

    assert_received {:command, ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"]}
    assert_received {:command, ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"]}
  end

  test "does not close already closed issues" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {:ok, {Jason.encode!(%{"state" => "CLOSED"}), 0}}

        "/tmp/fake-gh", ["issue", "close" | _args], _opts ->
          flunk("already closed issue should not be closed again")
      end
    }

    assert {:ok, :already_closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "ignores issue URLs for another repository" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _cmd, _args, _opts ->
        flunk("repo-mismatched issue URL should not call gh")
      end
    }

    assert {:ok, :not_applicable} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/other/repo/issues/67",
               "done via PR",
               deps
             )
  end
end
