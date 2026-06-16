defmodule SymphonyElixir.GitHubPrPublisherTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check
  alias SymphonyElixir.GitHubPrPublisher
  alias SymphonyElixir.Linear.Issue

  import ExUnit.CaptureIO

  test "publishes dirty workspace changes and returns created draft PR" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["check-ref-format", "--branch", branch]} ->
            {:ok, {branch <> "\n", 0}}

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

    assert_received {:command, "/bin/git", ["check-ref-format", "--branch", "aenima611111/lab-236"], _opts}
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
    assert body =~ "Fixes #236"
    assert_runtime_pr_body_lints(body)
  end

  test "does not publish when workspace has no changes" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/clean"], _opts -> {:ok, {"feature/clean\n", 0}}
        "/bin/git", ["-C", "/work/clean", "status", "--porcelain", "--", "." | _pathspecs], _opts -> {:ok, {"", 0}}
      end
    }

    assert {:error, :no_workspace_changes} =
             GitHubPrPublisher.publish_workspace("/work/clean", "feature/clean", %Issue{identifier: "LAB-1"}, deps)
  end

  test "returns an error when required binaries are missing" do
    assert {:error, :git_not_found} =
             GitHubPrPublisher.publish_workspace(
               "/work/missing-git",
               "feature/missing-git",
               %Issue{identifier: "LAB-1"},
               %{
                 find_git_bin: fn -> nil end,
                 find_gh_bin: fn -> "/bin/gh" end,
                 run_command: fn _cmd, _args, _opts -> flunk("commands should not run without git") end
               }
             )

    assert {:error, :gh_not_found} =
             GitHubPrPublisher.publish_workspace(
               "/work/missing-gh",
               "feature/missing-gh",
               %Issue{identifier: "LAB-1"},
               %{
                 find_git_bin: fn -> "/bin/git" end,
                 find_gh_bin: fn -> nil end,
                 run_command: fn _cmd, _args, _opts -> flunk("commands should not run without gh") end
               }
             )
  end

  test "returns an error for unsupported remotes" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/unsupported"], _opts ->
          {:ok, {"feature/unsupported\n", 0}}

        "/bin/git", ["-C", "/work/unsupported", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/unsupported", "remote", "get-url", "origin"], _opts ->
          {:ok, {"ssh://git.example.com/octo/repo.git\n", 0}}
      end
    }

    assert {:error, {:unsupported_remote_url, "ssh://git.example.com/octo/repo.git"}} =
             GitHubPrPublisher.publish_workspace(
               "/work/unsupported",
               "feature/unsupported",
               %Issue{identifier: "LAB-1"},
               deps
             )
  end

  test "sets missing git identity and creates body without source GitHub issue" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["check-ref-format", "--branch", branch]} ->
            {:ok, {branch <> "\n", 0}}

          {"/bin/git", ["-C", "/work/no-identity", "status", "--porcelain", "--", "." | _pathspecs]} ->
            {:ok, {" M README.md\n", 0}}

          {"/bin/git", ["-C", "/work/no-identity", "remote", "get-url", "origin"]} ->
            {:ok, {"https://github.com/octo/repo.git\n", 0}}

          {"/bin/git", ["-C", "/work/no-identity", "rev-parse", "--abbrev-ref", "origin/HEAD"]} ->
            {:ok, {"origin/HEAD\n", 0}}

          {"/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]} ->
            {:ok, {"main\n", 0}}

          {"/bin/git", ["-C", "/work/no-identity", "config", "--get", _key]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/no-identity", "config", _key, _value]} ->
            {:ok, {"", 0}}

          {"/bin/git", ["-C", "/work/no-identity", "diff", "--cached", "--quiet"]} ->
            {:ok, {"", 1}}

          {"/bin/git", ["-C", "/work/no-identity" | _rest]} ->
            {:ok, {"", 0}}

          {"/bin/gh", ["pr", "create" | _rest]} ->
            {:ok, {"https://github.com/octo/repo/pull/99\n", 0}}

          {"/bin/gh", ["pr", "list" | _rest]} ->
            {:ok, {"[]", 0}}
        end
      end
    }

    assert {:ok, %{"url" => "https://github.com/octo/repo/pull/99", "headRefName" => "feature/no-identity"}} =
             GitHubPrPublisher.publish_workspace(
               "/work/no-identity",
               "feature/no-identity",
               %Issue{identifier: "LAB-99", title: "No source issue"},
               deps
             )

    assert_received {:command, "/bin/git", ["-C", "/work/no-identity", "config", "user.name", "Symphony Runtime"], _opts}
    assert_received {:command, "/bin/git", ["-C", "/work/no-identity", "config", "user.email", "symphony-runtime@users.noreply.github.com"], _opts}

    assert_received {:command, "/bin/gh",
                     [
                       "pr",
                       "create",
                       "--repo",
                       "octo/repo",
                       "--head",
                       "feature/no-identity",
                       "--base",
                       "main",
                       "--title",
                       "[codex] LAB-99 No source issue",
                       "--body",
                       body,
                       "--draft"
                     ], _opts}

    assert body =~ "Linear: n/a"
    refute body =~ "Source GitHub issue:"
    refute body =~ "Fixes #"
    assert_runtime_pr_body_lints(body)
  end

  test "returns an error when add produces no staged changes" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/no-staged"], _opts ->
          {:ok, {"feature/no-staged\n", 0}}

        "/bin/git", ["-C", "/work/no-staged", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/no-staged", "remote", "get-url", "origin"], _opts ->
          {:ok, {"git@github.com:octo/repo.git\n", 0}}

        "/bin/git", ["-C", "/work/no-staged", "rev-parse", "--abbrev-ref", "origin/HEAD"], _opts ->
          {:ok, {"main\n", 0}}

        "/bin/git", ["-C", "/work/no-staged", "config", "--get", _key], _opts ->
          {:ok, {"Test User\n", 0}}

        "/bin/git", ["-C", "/work/no-staged", "diff", "--cached", "--quiet"], _opts ->
          {:ok, {"", 0}}

        "/bin/git", ["-C", "/work/no-staged" | _rest], _opts ->
          {:ok, {"", 0}}
      end
    }

    assert {:error, :no_staged_changes} =
             GitHubPrPublisher.publish_workspace(
               "/work/no-staged",
               "feature/no-staged",
               %Issue{identifier: "LAB-1"},
               deps
             )
  end

  test "returns an error when GitHub default branch lookup fails" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/no-default"], _opts ->
          {:ok, {"feature/no-default\n", 0}}

        "/bin/git", ["-C", "/work/no-default", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/no-default", "remote", "get-url", "origin"], _opts ->
          {:ok, {"git@github.com:octo/repo.git\n", 0}}

        "/bin/git", ["-C", "/work/no-default", "rev-parse", "--abbrev-ref", "origin/HEAD"], _opts ->
          {:ok, {"origin/HEAD\n", 0}}

        "/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], _opts ->
          {:ok, {"missing repository", 1}}
      end
    }

    assert {:error, {:gh_default_branch_failed, 1, "missing repository"}} =
             GitHubPrPublisher.publish_workspace(
               "/work/no-default",
               "feature/no-default",
               %Issue{identifier: "LAB-1"},
               deps
             )
  end

  test "returns an error when GitHub default branch lookup is blank" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/blank-default"], _opts ->
          {:ok, {"feature/blank-default\n", 0}}

        "/bin/git", ["-C", "/work/blank-default", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/blank-default", "remote", "get-url", "origin"], _opts ->
          {:ok, {"git@github.com:octo/repo.git\n", 0}}

        "/bin/git", ["-C", "/work/blank-default", "rev-parse", "--abbrev-ref", "origin/HEAD"], _opts ->
          {:ok, {"origin/HEAD\n", 0}}

        "/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], _opts ->
          {:ok, {"\n", 0}}
      end
    }

    assert {:error, :default_branch_not_found} =
             GitHubPrPublisher.publish_workspace(
               "/work/blank-default",
               "feature/blank-default",
               %Issue{identifier: "LAB-1"},
               deps
             )
  end

  test "returns an error when GitHub default branch command errors" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature/error-default"], _opts ->
          {:ok, {"feature/error-default\n", 0}}

        "/bin/git", ["-C", "/work/error-default", "status", "--porcelain", "--", "." | _pathspecs], _opts ->
          {:ok, {" M file.txt\n", 0}}

        "/bin/git", ["-C", "/work/error-default", "remote", "get-url", "origin"], _opts ->
          {:ok, {"git@github.com:octo/repo.git\n", 0}}

        "/bin/git", ["-C", "/work/error-default", "rev-parse", "--abbrev-ref", "origin/HEAD"], _opts ->
          {:ok, {"origin/HEAD\n", 0}}

        "/bin/gh", ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], _opts ->
          {:error, :network_down}
      end
    }

    assert {:error, {:gh_default_branch_failed, :network_down}} =
             GitHubPrPublisher.publish_workspace(
               "/work/error-default",
               "feature/error-default",
               %Issue{identifier: "LAB-1"},
               deps
             )
  end

  test "pushes rework commits and returns existing PR when branch already has one" do
    parent = self()

    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn cmd, args, opts ->
        send(parent, {:command, cmd, args, opts})

        case {cmd, args} do
          {"/bin/git", ["check-ref-format", "--branch", branch]} ->
            {:ok, {branch <> "\n", 0}}

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
          {"/bin/git", ["check-ref-format", "--branch", branch]} ->
            {:ok, {branch <> "\n", 0}}

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
        "/bin/git", ["check-ref-format", "--branch", "feature/no-url"], _opts ->
          {:ok, {"feature/no-url\n", 0}}

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

  test "rejects unsafe branch names before running git workspace commands" do
    invalid_branches = [
      {"", :empty},
      {"-foo", :leading_dash},
      {"feature/has space", :whitespace},
      {"feature..name", :dotdot},
      {"feature/\nname", :control_character}
    ]

    for {branch, reason} <- invalid_branches do
      deps = %{
        find_git_bin: fn -> "/bin/git" end,
        find_gh_bin: fn -> "/bin/gh" end,
        run_command: fn _cmd, _args, _opts -> flunk("commands should not run for invalid branch #{inspect(branch)}") end
      }

      assert {:error, {:invalid_branch_name, ^reason}} =
               GitHubPrPublisher.publish_workspace("/work/unsafe", branch, %Issue{identifier: "LAB-420"}, deps)
    end
  end

  test "rejects branch names that git check-ref-format rejects" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "feature.lock"], _opts -> {:ok, {"invalid ref\n", 1}}
        _cmd, _args, _opts -> flunk("workspace commands should not run after git rejects branch")
      end
    }

    assert {:error, {:invalid_branch_name, :git_check_ref_format}} =
             GitHubPrPublisher.publish_workspace("/work/unsafe", "feature.lock", %Issue{identifier: "LAB-420"}, deps)
  end

  test "rejects branch names that git expands before running workspace commands" do
    deps = %{
      find_git_bin: fn -> "/bin/git" end,
      find_gh_bin: fn -> "/bin/gh" end,
      run_command: fn
        "/bin/git", ["check-ref-format", "--branch", "@{-1}"], _opts ->
          {:ok, {"main\n", 0}}

        "/bin/git", ["-C", "/work/unsafe" | _rest], _opts ->
          flunk("workspace commands should not run after git expands branch magic")

        _cmd, _args, _opts ->
          flunk("unexpected command after git expands branch magic")
      end
    }

    assert {:error, {:invalid_branch_name, :git_check_ref_format}} =
             GitHubPrPublisher.publish_workspace("/work/unsafe", "@{-1}", %Issue{identifier: "LAB-420"}, deps)
  end

  defp assert_runtime_pr_body_lints(body) do
    Enum.each(["#### Context", "#### TL;DR", "#### Summary", "#### Alternatives", "#### Test Plan"], fn heading ->
      assert body =~ heading
    end)

    path = Path.join(System.tmp_dir!(), "runtime-pr-body-#{System.unique_integer([:positive, :monotonic])}.md")
    File.write!(path, body)

    try do
      Mix.Task.reenable("pr_body.check")

      output =
        capture_io(fn ->
          Check.run(["--file", path])
        end)

      assert output =~ "PR body format OK"
    after
      File.rm(path)
    end
  end
end
