defmodule SymphonyElixir.GitHubPrPublisherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPrPublisher
  alias SymphonyElixir.Linear.Issue

  test "publishes dirty workspace changes and returns created draft PR" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["-C", "/work/LAB-236", "status", "--porcelain"]} ->
            {:ok, {" M docs/file.md\n?? docs/new.md\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/main\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "config", "--get", _key]} ->
            {:ok, {"Test User\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/LAB-236" | _rest]} ->
            {:ok, {"", 0}}

          {"/bin/gh", ["pr", "create" | _rest]} ->
            {:ok, {"https://github.com/octo/repo/pull/236\n", 0}}

          {"/bin/gh", ["pr", "list" | _rest]} ->
            {:ok,
             {
               Jason.encode!([
                 %{
                   "number" => 236,
                   "url" => "https://github.com/octo/repo/pull/236",
                   "headRefName" => "aenima611111/lab-236",
                   "isDraft" => true,
                   "mergeStateStatus" => "UNKNOWN"
                 }
               ]),
               0
             }}
        end
      end
    }

    issue = %Issue{
      identifier: "LAB-236",
      title: "Smoke: verify runtime publish",
      url: "https://linear.app/ryo-work/issue/LAB-236/test",
      description: "Source: https://github.com/octo/repo/issues/236"
    }

    assert {:ok, %{"number" => 236, "url" => "https://github.com/octo/repo/pull/236"}} =
             GitHubPrPublisher.publish_workspace("/work/LAB-236", "aenima611111/lab-236", issue, deps)

    assert_received {:command, "/bin/git", ["-C", "/work/LAB-236", "checkout", "-B", "aenima611111/lab-236"], _opts}
    assert_received {:command, "/bin/git", ["-C", "/work/LAB-236", "push", "-u", "origin", "HEAD:refs/heads/aenima611111/lab-236"], _opts}

    assert_received {:command, "/bin/gh",
                     [
                       "pr",
                       "create",
                       "--repo",
                       "octo/repo",
                       "--head",
                       "aenima611111/lab-236",
                       "--base",
                       "main",
                       "--title",
                       "[codex] LAB-236 Smoke: verify runtime publish",
                       "--body",
                       body,
                       "--draft"
                     ], _opts}

    assert body =~ "PR URL is required before In Review handoff"
    assert body =~ "https://linear.app/ryo-work/issue/LAB-236/test"
    assert body =~ "Source GitHub issue: https://github.com/octo/repo/issues/236"
  end

  test "does not publish when workspace has no changes" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["-C", "/work/clean", "status", "--porcelain"], _opts -> {:ok, {"", 0}}
      end
    }

    assert {:error, :no_workspace_changes} =
             GitHubPrPublisher.publish_workspace("/work/clean", "feature/clean", %Issue{identifier: "LAB-1"}, deps)
  end

  test "pushes rework commits and returns existing PR when branch already has one" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["-C", "/work/LAB-238", "status", "--porcelain"]} ->
            {:ok, {" M lib/file.ex\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/main\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "config", "--get", _key]} ->
            {:ok, {"Test User\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/LAB-238" | _rest]} ->
            {:ok, {"", 0}}

          {"/bin/gh", ["pr", "create" | _rest]} ->
            {:ok, {"a pull request already exists for octo:feature/lab-238\n", 1}}

          {"/bin/gh", ["pr", "list" | _rest]} ->
            {:ok,
             {
               Jason.encode!([
                 %{
                   "number" => 238,
                   "url" => "https://github.com/octo/repo/pull/238",
                   "headRefName" => "feature/lab-238",
                   "isDraft" => true,
                   "mergeStateStatus" => "UNKNOWN"
                 }
               ]),
               0
             }}
        end
      end
    }

    assert {:ok, %{"number" => 238, "url" => "https://github.com/octo/repo/pull/238"}} =
             GitHubPrPublisher.publish_workspace("/work/LAB-238", "feature/lab-238", %Issue{identifier: "LAB-238"}, deps)

    assert_received {:command, "/bin/git", ["-C", "/work/LAB-238", "commit", "-m", "LAB-238: Automated changes"], _opts}
    assert_received {:command, "/bin/git", ["-C", "/work/LAB-238", "push", "-u", "origin", "HEAD:refs/heads/feature/lab-238"], _opts}
    assert_received {:command, "/bin/gh", ["pr", "create" | _rest], _opts}
    assert_received {:command, "/bin/gh", ["pr", "list" | _rest], _opts}
  end
end
