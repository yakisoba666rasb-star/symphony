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
          {"/bin/git", ["-C", "/work/LAB-236", "status", "--porcelain", "--", "." | _pathspecs]} ->
            {:ok, {" M docs/file.md\n?? docs/new.md\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/main\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "config", "--get", _key]} ->
            {:ok, {"Test User\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-236", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/LAB-236", "rev-parse", "--git-dir"]} ->
            {:ok, {".git\n", 0}}

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
                   "mergeStateStatus" => "UNKNOWN",
                   "state" => "OPEN"
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
    assert_received {:command, "/bin/git", ["-C", "/work/LAB-236", "add", "-A", "--", ".", ":!.symphony-review-verdict.json", ":!.symphony-review-verdict-*.json"], _opts}
    assert_received {:command, "/bin/git", ["-C", "/work/LAB-236", "push", "--force-with-lease", "-u", "origin", "HEAD:refs/heads/aenima611111/lab-236"], _opts}

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

  test "returns issue-linked PR when workspace is clean and head branch lookup would miss it" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["-C", "/work/clean", "status", "--porcelain", "--", "." | _pathspecs]} ->
            {:ok, {"", 0}}

          {"/bin/git", ["-C", "/work/clean", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/gh", ["pr", "list" | rest]} ->
            assert Enum.member?(rest, "--search")
            assert Enum.member?(rest, "LAB-374 in:title,body")

            {:ok,
             {Jason.encode!([
                %{
                  "number" => 73,
                  "url" => "https://github.com/octo/repo/pull/73",
                  "headRefName" => "LAB-374-android-release-config",
                  "isDraft" => false,
                  "mergeStateStatus" => "CLEAN",
                  "state" => "OPEN"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{"number" => 73, "headRefName" => "LAB-374-android-release-config"}} =
             GitHubPrPublisher.publish_workspace("/work/clean", "aenima611111/lab-374", %Issue{identifier: "LAB-374"}, deps)

    refute_received {:command, "/bin/git", ["-C", "/work/clean", "checkout" | _rest], _opts}
    refute_received {:command, "/bin/git", ["-C", "/work/clean", "commit" | _rest], _opts}
    refute_received {:command, "/bin/git", ["-C", "/work/clean", "push" | _rest], _opts}
  end

  test "does not publish clean workspace when no issue-linked PR is found" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["-C", "/work/clean", "status", "--porcelain", "--", "." | _pathspecs], _opts -> {:ok, {"", 0}}
        "/bin/git", ["-C", "/work/clean", "remote", "get-url", "origin"], _opts -> {:ok, {"git@github.com:octo/repo.git\n", 0}}
        "/bin/gh", ["pr", "list" | _rest], _opts -> {:ok, {"[]", 0}}
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
          {"/bin/git", ["-C", "/work/LAB-238", "status", "--porcelain", "--", "." | _pathspecs]} ->
            {:ok, {" M lib/file.ex\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/main\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "config", "--get", _key]} ->
            {:ok, {"Test User\n", 0}}

          {"/bin/git", ["-C", "/work/LAB-238", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/LAB-238", "rev-parse", "--git-dir"]} ->
            {:ok, {".git\n", 0}}

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
                   "mergeStateStatus" => "UNKNOWN",
                   "state" => "OPEN"
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
    assert_received {:command, "/bin/git", ["-C", "/work/LAB-238", "push", "--force-with-lease", "-u", "origin", "HEAD:refs/heads/feature/lab-238"], _opts}
    assert_received {:command, "/bin/gh", ["pr", "create" | _rest], _opts}
    assert_received {:command, "/bin/gh", ["pr", "list" | _rest], _opts}
  end

  test "falls back to GitHub default branch when origin HEAD is unavailable" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["-C", "/work/master-repo", "status", "--porcelain", "--", "." | _pathspecs]} ->
            {:ok, {" M README.md\n", 0}}

          {"/bin/git", ["-C", "/work/master-repo", "remote", "get-url", "origin"]} ->
            {:ok, {"git@github.com:octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/master-repo", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/HEAD\n", 0}}

          {"/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]} ->
            {:ok, {"master\n", 0}}

          {"/bin/git", ["-C", "/work/master-repo", "config", "--get", _key]} ->
            {:ok, {"Test User\n", 0}}

          {"/bin/git", ["-C", "/work/master-repo", "rev-parse", "--git-dir"]} ->
            {:ok, {".git\n", 0}}

          {"/bin/git", ["-C", "/work/master-repo", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/master-repo" | _rest]} ->
            {:ok, {"", 0}}

          {"/bin/gh", ["pr", "create" | _rest]} ->
            {:ok, {"https://github.com/octo/repo/pull/240\n", 0}}

          {"/bin/gh", ["pr", "list" | _rest]} ->
            {:ok,
             {Jason.encode!([
                %{
                  "number" => 240,
                  "url" => "https://github.com/octo/repo/pull/240",
                  "headRefName" => "feature/master",
                  "isDraft" => true,
                  "mergeStateStatus" => "UNKNOWN",
                  "state" => "OPEN"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{"number" => 240}} =
             GitHubPrPublisher.publish_workspace("/work/master-repo", "feature/master", %Issue{identifier: "LAB-240"}, deps)

    assert_received {:command, "/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], _opts}
    assert_received {:command, "/bin/gh", ["pr", "create", "--repo", "octo/repo", "--head", "feature/master", "--base", "master" | _rest], _opts}
  end

  test "returns an error when gh create succeeds without a PR URL and no existing PR is found" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["-C", "/work/no-url", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/no-url", "remote", "get-url", "origin"], _opts ->
          {:ok, {"git@github.com:octo/repo.git\n", 0}}

        "/bin/git", ["-C", "/work/no-url", "rev-parse", "--abbrev-ref", "origin/HEAD"], _opts ->
          {:ok, {"origin/main\n", 0}}

        "/bin/git", ["-C", "/work/no-url", "config", "--get", _key], _opts ->
          {:ok, {"Test User\n", 0}}

        "/bin/git", ["-C", "/work/no-url", "rev-parse", "--git-dir"], _opts ->
          {:ok, {".git\n", 0}}

        "/bin/git", ["-C", "/work/no-url", "diff", "--cached", "--quiet"], _opts ->
          {:ok, {"", 1}}

        "/bin/git", ["-C", "/work/no-url" | _rest], _opts ->
          {:ok, {"", 0}}

        "/bin/gh", ["pr", "create" | _rest], _opts ->
          {:ok, {"Created pull request successfully\n", 0}}

        "/bin/gh", ["pr", "list" | _rest], _opts ->
          {:ok, {"[]", 0}}
      end
    }

    assert {:error, :pr_url_not_found} =
             GitHubPrPublisher.publish_workspace("/work/no-url", "feature/no-url", %Issue{identifier: "LAB-241"}, deps)
  end
end
