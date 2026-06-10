defmodule SymphonyElixir.GitHubIssueTest do
  use ExUnit.Case

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

  test "closes open source issue through default runtime dependencies" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-fake-gh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    gh_path = Path.join(tmp_dir, "gh")

    File.write!(gh_path, """
    #!/bin/sh
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      printf '{"state":"OPEN"}'
      exit 0
    fi
    if [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      printf 'closed'
      exit 0
    fi
    exit 2
    """)

    File.chmod!(gh_path, 0o755)

    original_path = System.get_env("PATH", "")
    System.put_env("PATH", tmp_dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf(tmp_dir)
    end)

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR"
             )
  end

  test "accepts raw System.cmd style command tuples" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {Jason.encode!(%{"state" => "OPEN"}), 0}

        "/tmp/fake-gh", ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"], _opts ->
          {"closed\n", 0}
      end
    }

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
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

  test "ignores malformed or missing issue URLs" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _cmd, _args, _opts ->
        flunk("malformed issue URL should not call gh")
      end
    }

    assert {:ok, :not_applicable} = GitHubIssue.close_if_open("octo/repo", nil, "done via PR", deps)

    assert {:ok, :not_applicable} =
             GitHubIssue.close_if_open("octo/repo", "https://github.com/octo/repo/pull/67", "done via PR", deps)
  end

  test "returns gh lookup errors" do
    deps = %{
      find_gh_bin: fn -> nil end,
      run_command: fn _cmd, _args, _opts ->
        flunk("missing gh binary should stop before running commands")
      end
    }

    assert {:error, :gh_not_found} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns view command failures" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {"not found", 1}}
      end
    }

    assert {:error, {:gh_issue_view_failed, 1, "not found"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns invalid view payload errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {Jason.encode!(%{"number" => 67}), 0}}
      end
    }

    assert {:error, {:invalid_issue_payload, %{"number" => 67}}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns invalid view json errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {"{", 0}}
      end
    }

    assert {:error, {:gh_json_error, %Jason.DecodeError{}}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns unexpected issue state errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {Jason.encode!(%{"state" => "MERGED"}), 0}}
      end
    }

    assert {:error, {:unexpected_issue_state, "MERGED"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns close command failures" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {:ok, {Jason.encode!(%{"state" => "OPEN"}), 0}}

        "/tmp/fake-gh", ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"], _opts ->
          {:ok, {"permission denied", 1}}
      end
    }

    assert {:error, {:gh_issue_close_failed, 1, "permission denied"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end
end
