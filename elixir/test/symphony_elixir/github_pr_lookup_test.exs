defmodule SymphonyElixir.GitHubPrLookupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubPrLookup

  @gh_not_found_error :gh_not_found

  test "returns ok nil when gh list output is empty" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {:ok, {"[]", 0}}
      end
    }

    assert {:ok, nil} = GitHubPrLookup.lookup_by_head("octo/repo", "feature/no-pr", deps)
  end

  test "returns the first open PR from gh JSON output" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn gh, args, _opts ->
        send(parent, {:command, gh, args})

        json =
          Jason.encode!([
            %{
              "number" => 123,
              "url" => "https://github.com/octo/repo/pull/123",
              "headRefName" => "feature/head-branch",
              "isDraft" => false,
              "mergeStateStatus" => "CLEAN",
              "state" => "OPEN"
            },
            %{
              "number" => 456,
              "url" => "https://github.com/octo/repo/pull/456",
              "headRefName" => "feature/other-branch",
              "isDraft" => true,
              "mergeStateStatus" => "UNKNOWN",
              "state" => "OPEN"
            }
          ])

        {:ok, {json, 0}}
      end
    }

    assert {:ok, %{"number" => 123, "headRefName" => "feature/head-branch"} = pr} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/head-branch", deps)

    assert pr == %{
             "number" => 123,
             "url" => "https://github.com/octo/repo/pull/123",
             "headRefName" => "feature/head-branch",
             "isDraft" => false,
             "mergeStateStatus" => "CLEAN",
             "state" => "OPEN"
           }

    assert_received {
      :command,
      "/tmp/fake-gh",
      [
        "pr",
        "list",
        "--repo",
        "octo/repo",
        "--state",
        "open",
        "--json",
        "number,url,headRefName,isDraft,mergeStateStatus,state",
        "--head",
        "feature/head-branch"
      ]
    }
  end

  test "falls back to all states only when no open PR exists" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn gh, args, _opts ->
        send(parent, {:command, gh, args})

        case Enum.at(args, Enum.find_index(args, &(&1 == "--state")) + 1) do
          "open" ->
            {:ok, {"[]", 0}}

          "all" ->
            {:ok,
             {Jason.encode!([
                %{
                  "number" => 10,
                  "url" => "https://github.com/octo/repo/pull/10",
                  "headRefName" => "feature/reused",
                  "isDraft" => false,
                  "mergeStateStatus" => "CLEAN",
                  "state" => "MERGED"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{"number" => 10}} = GitHubPrLookup.lookup_by_head("octo/repo", "feature/reused", deps)

    assert_received {:command, "/tmp/fake-gh", ["pr", "list", "--repo", "octo/repo", "--state", "open" | _]}
    assert_received {:command, "/tmp/fake-gh", ["pr", "list", "--repo", "octo/repo", "--state", "all" | _]}
  end

  test "open PR lookup avoids stale closed PRs from all-state results" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, args, _opts ->
        case Enum.at(args, Enum.find_index(args, &(&1 == "--state")) + 1) do
          "open" ->
            {:ok,
             {Jason.encode!([
                %{
                  "number" => 12,
                  "url" => "https://github.com/octo/repo/pull/12",
                  "headRefName" => "feature/reused",
                  "isDraft" => true,
                  "mergeStateStatus" => "UNKNOWN",
                  "state" => "OPEN"
                }
              ]), 0}}

          "all" ->
            flunk("all-state lookup should not run when open lookup finds a PR")
        end
      end
    }

    assert {:ok, %{"number" => 12, "state" => "OPEN"}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/reused", deps)
  end

  test "sorts candidate PRs by open state, draft status, merge state, and number" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 5, "state" => "CLOSED", "isDraft" => false, "mergeStateStatus" => "CLEAN"},
            %{"number" => 6, "state" => "OPEN", "isDraft" => true, "mergeStateStatus" => "HAS_HOOKS"},
            %{"number" => 7, "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "DIRTY"},
            %{"number" => 8, "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN"},
            %{"number" => 9, "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "HAS_HOOKS"},
            %{"number" => "10", "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "BLOCKED"}
          ]), 0}}
      end
    }

    assert {:ok, %{"number" => 9, "mergeStateStatus" => "HAS_HOOKS"}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/sorted", deps)
  end

  test "returns error when gh binary is missing" do
    deps = %{find_gh_bin: fn -> nil end, run_command: fn _gh, _args, _opts -> {:error, :unused} end}

    assert {:error, @gh_not_found_error} = GitHubPrLookup.lookup_by_head("octo/repo", "feature/missing", deps)
  end

  test "returns error when gh command fails" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts -> {:error, :no_such_file} end
    }

    assert {:error, {:gh_command_failed, :no_such_file}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/fail", deps)
  end

  test "returns error when gh command exits with a non-zero status" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts -> {:ok, {"bad credentials", 4}} end
    }

    assert {:error, {:gh_command_failed, 4}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/fail-status", deps)
  end

  test "accepts raw {output, status} shape from run_command" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {
          Jason.encode!([
            %{
              "number" => 999,
              "url" => "https://github.com/octo/repo/pull/999",
              "headRefName" => "feature/raw-shape",
              "isDraft" => false,
              "mergeStateStatus" => "CLEAN",
              "state" => "OPEN"
            }
          ]),
          0
        }
      end
    }

    assert {:ok, %{"number" => 999, "headRefName" => "feature/raw-shape"}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/raw-shape", deps)
  end

  test "returns error when gh output is invalid JSON" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {:ok, {"not valid json", 0}}
      end
    }

    assert {:error, {:gh_json_error, _}} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/bad-json", deps)
  end

  test "returns error when gh JSON payload is not a PR list" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {:ok, {Jason.encode!(%{"message" => "not a list"}), 0}}
      end
    }

    assert {:error, :invalid_pr_payload} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/bad-payload", deps)
  end

  test "returns error when gh JSON list contains no PR maps" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts ->
        {:ok, {Jason.encode!(["not-a-pr"]), 0}}
      end
    }

    assert {:error, :invalid_pr_payload} =
             GitHubPrLookup.lookup_by_head("octo/repo", "feature/no-pr-maps", deps)
  end

  test "resolves repository from SSH GitHub remote URL" do
    workspace = "/tmp/owner-workspace-ssh"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:ok, {"git@github.com:octo/repo.git", 0}}

        "/tmp/fake-gh", _args, _opts ->
          {:ok,
           {Jason.encode!([%{"number" => 1, "url" => "https://github.com/octo/repo/pull/1", "headRefName" => "feature/branch", "isDraft" => false, "mergeStateStatus" => "CLEAN", "state" => "OPEN"}]),
            0}}
      end
    }

    assert {:ok, %{"number" => 1, "headRefName" => "feature/branch"}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/branch", deps)
  end

  test "resolves repository from HTTPS GitHub remote URL" do
    workspace = "/tmp/owner-workspace-https"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:ok, {"https://github.com/octo/repo.git", 0}}

        "/tmp/fake-gh", _args, _opts ->
          {:ok,
           {Jason.encode!([%{"number" => 2, "url" => "https://github.com/octo/repo/pull/2", "headRefName" => "feature/http", "isDraft" => false, "mergeStateStatus" => "CLEAN", "state" => "OPEN"}]), 0}}
      end
    }

    assert {:ok, %{"number" => 2, "headRefName" => "feature/http"}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/http", deps)
  end

  test "workspace handoff lookup uses linked PR attachment when branch lookup misses" do
    workspace = "/tmp/owner-workspace-linked-pr"
    parent = self()

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          send(parent, {:command, :git, args})
          {:ok, {"https://github.com/octo/repo.git", 0}}

        "/tmp/fake-gh", args, _opts ->
          send(parent, {:command, :gh, args})

          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", "feature/linear"] ->
              {:ok, {"[]", 0}}

            ["pr", "view", "79", "--repo", "octo/repo", "--json", _fields] ->
              {:ok,
               {Jason.encode!(%{
                  "number" => 79,
                  "url" => "https://github.com/octo/repo/pull/79",
                  "headRefName" => "feature/actual-pr",
                  "isDraft" => false,
                  "mergeStateStatus" => "CLEAN",
                  "state" => "OPEN"
                }), 0}}
          end
      end
    }

    assert {:ok,
            %{
              "number" => 79,
              "headRefName" => "feature/actual-pr",
              "__symphonyLookupSource" => "linked_pull_request",
              "__symphonyExpectedBranch" => "feature/linear"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )

    assert_received {:command, :git, ["-C", ^workspace, "remote", "get-url", "origin"]}
    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "open" | _]}
    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "all" | _]}
    assert_received {:command, :gh, ["pr", "view", "79", "--repo", "octo/repo", "--json", _fields]}
  end

  test "workspace handoff lookup uses workspace branch when Linear branch lookup misses" do
    workspace = "/tmp/owner-workspace-branch-fallback"
    parent = self()

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          send(parent, {:command, :git, args})

          case args do
            ["-C", ^workspace, "remote", "get-url", "origin"] ->
              {:ok, {"https://github.com/octo/repo.git", 0}}

            ["-C", ^workspace, "branch", "--show-current"] ->
              {:ok, {"lab-379-brace-expansion-audit\n", 0}}

            ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] ->
              {:ok, {"origin/lab-379-brace-expansion-audit\n", 0}}
          end

        "/tmp/fake-gh", args, _opts ->
          send(parent, {:command, :gh, args})

          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", "feature/linear"] ->
              {:ok, {"[]", 0}}

            ["pr", "list", "--repo", "octo/repo", "--state", "open", "--json", _fields, "--head", "lab-379-brace-expansion-audit"] ->
              {:ok,
               {Jason.encode!([
                  %{
                    "number" => 200,
                    "url" => "https://github.com/octo/repo/pull/200",
                    "headRefName" => "lab-379-brace-expansion-audit",
                    "isDraft" => false,
                    "mergeStateStatus" => "CLEAN",
                    "state" => "OPEN"
                  }
                ]), 0}}
          end
      end
    }

    assert {:ok,
            %{
              "number" => 200,
              "headRefName" => "lab-379-brace-expansion-audit",
              "__symphonyLookupSource" => "workspace_branch",
              "__symphonyExpectedBranch" => "feature/linear",
              "__symphonyMatchedBranch" => "lab-379-brace-expansion-audit"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               [],
               deps
             )

    assert_received {:command, :git, ["-C", ^workspace, "remote", "get-url", "origin"]}
    assert_received {:command, :git, ["-C", ^workspace, "branch", "--show-current"]}
    assert_received {:command, :git, ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]}
    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "open", "--json", _fields, "--head", "feature/linear"]}
    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "all", "--json", _fields, "--head", "feature/linear"]}
    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "open", "--json", _fields, "--head", "lab-379-brace-expansion-audit"]}
  end

  test "workspace handoff lookup uses workspace head sha when branch names diverge" do
    workspace = "/tmp/owner-workspace-head-sha-fallback"
    parent = self()
    head_sha = "c346f466a2cf61b390b75160b9a760c62345d6f3"
    commit_pulls_path = "/repos/octo/repo/commits/#{head_sha}/pulls"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          send(parent, {:command, :git, args})

          case args do
            ["-C", ^workspace, "remote", "get-url", "origin"] ->
              {:ok, {"https://github.com/octo/repo.git", 0}}

            ["-C", ^workspace, "branch", "--show-current"] ->
              {:ok, {"lab-381-dedupe-slack-handoff\n", 0}}

            ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] ->
              {:ok, {"origin/lab-381-dedupe-slack-handoff\n", 0}}

            ["-C", ^workspace, "rev-parse", "HEAD"] ->
              {:ok, {head_sha <> "\n", 0}}
          end

        "/tmp/fake-gh", args, _opts ->
          send(parent, {:command, :gh, args})

          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", _head] ->
              {:ok, {"[]", 0}}

            ["api", "-H", "Accept: application/vnd.github+json", ^commit_pulls_path] ->
              {:ok,
               {Jason.encode!([
                  %{
                    "number" => 204,
                    "html_url" => "https://github.com/octo/repo/pull/204",
                    "head" => %{
                      "ref" => "lab-381-dedupe-slack-handoff",
                      "sha" => head_sha
                    },
                    "draft" => false,
                    "mergeable_state" => "clean",
                    "state" => "open"
                  }
                ]), 0}}
          end
      end
    }

    assert {:ok,
            %{
              "number" => 204,
              "headRefName" => "lab-381-dedupe-slack-handoff",
              "__symphonyLookupSource" => "workspace_head_sha",
              "__symphonyExpectedBranch" => "aenima611111/linear-generated-branch",
              "__symphonyMatchedBranch" => "lab-381-dedupe-slack-handoff"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "aenima611111/linear-generated-branch",
               [],
               deps
             )

    assert_received {:command, :git, ["-C", ^workspace, "rev-parse", "HEAD"]}
    assert_received {:command, :gh, ["api", "-H", "Accept: application/vnd.github+json", ^commit_pulls_path]}
  end

  test "workspace handoff head sha lookup uses commit PR API instead of all-list fallback" do
    workspace = "/tmp/owner-workspace-head-sha-all-fallback"
    head_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    commit_pulls_path = "/repos/octo/repo/commits/#{head_sha}/pulls"
    parent = self()

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          case args do
            ["-C", ^workspace, "remote", "get-url", "origin"] -> {:ok, {"https://github.com/octo/repo.git", 0}}
            ["-C", ^workspace, "branch", "--show-current"] -> {:ok, {"workspace-branch\n", 0}}
            ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] -> {:ok, {"origin/workspace-branch\n", 0}}
            ["-C", ^workspace, "rev-parse", "HEAD"] -> {:ok, {head_sha <> "\n", 0}}
          end

        "/tmp/fake-gh", args, _opts ->
          send(parent, {:command, :gh, args})

          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", _head] ->
              {:ok, {"[]", 0}}

            ["api", "-H", "Accept: application/vnd.github+json", ^commit_pulls_path] ->
              {:ok,
               {Jason.encode!([
                  %{
                    "number" => 205,
                    "html_url" => "https://github.com/octo/repo/pull/205",
                    "head" => %{"ref" => "workspace-branch", "sha" => head_sha},
                    "draft" => false,
                    "mergeable_state" => "clean",
                    "state" => "open"
                  }
                ]), 0}}
          end
      end
    }

    assert {:ok,
            %{
              "number" => 205,
              "__symphonyLookupSource" => "workspace_head_sha"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "linear-branch",
               [],
               deps
             )

    refute_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "all", "--limit", "100" | _rest]}
  end

  test "workspace handoff head sha lookup returns nil without an open non-draft match" do
    workspace = "/tmp/owner-workspace-head-sha-no-match"
    head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    commit_pulls_path = "/repos/octo/repo/commits/#{head_sha}/pulls"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          case args do
            ["-C", ^workspace, "remote", "get-url", "origin"] -> {:ok, {"https://github.com/octo/repo.git", 0}}
            ["-C", ^workspace, "branch", "--show-current"] -> {:ok, {"workspace-branch\n", 0}}
            ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] -> {:ok, {"fatal: no upstream\n", 128}}
            ["-C", ^workspace, "rev-parse", "HEAD"] -> {:ok, {head_sha <> "\n", 0}}
          end

        "/tmp/fake-gh", args, _opts ->
          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", _head] ->
              {:ok, {"[]", 0}}

            ["api", "-H", "Accept: application/vnd.github+json", ^commit_pulls_path] ->
              {:ok,
               {Jason.encode!([
                  %{
                    "number" => 206,
                    "html_url" => "https://github.com/octo/repo/pull/206",
                    "head" => %{"ref" => "workspace-branch", "sha" => head_sha},
                    "draft" => true,
                    "mergeable_state" => "clean",
                    "state" => "open"
                  },
                  %{
                    "number" => 207,
                    "html_url" => "https://github.com/octo/repo/pull/207",
                    "head" => %{
                      "ref" => "workspace-branch",
                      "sha" => "cccccccccccccccccccccccccccccccccccccccc"
                    },
                    "draft" => false,
                    "mergeable_state" => "clean",
                    "state" => "open"
                  }
                ]), 0}}
          end
      end
    }

    assert {:ok, nil} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "linear-branch",
               [],
               deps
             )
  end

  test "workspace handoff lookup keeps branch PR as the primary source" do
    workspace = "/tmp/owner-workspace-branch-primary"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", _args, _opts ->
          {:ok, {"https://github.com/octo/repo.git", 0}}

        "/tmp/fake-gh", ["pr", "list" | _args], _opts ->
          {:ok,
           {Jason.encode!([
              %{
                "number" => 80,
                "url" => "https://github.com/octo/repo/pull/80",
                "headRefName" => "feature/linear",
                "isDraft" => false,
                "mergeStateStatus" => "CLEAN",
                "state" => "OPEN"
              }
            ]), 0}}

        "/tmp/fake-gh", ["pr", "view" | _args], _opts ->
          flunk("linked PR fallback should not run when branch lookup finds a PR")
      end
    }

    assert {:ok,
            %{
              "number" => 80,
              "__symphonyLookupSource" => "branch",
              "__symphonyExpectedBranch" => "feature/linear"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )
  end

  test "workspace handoff lookup rejects multiple linked PR attachments" do
    workspace = "/tmp/owner-workspace-ambiguous-linked-pr"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", _args, _opts ->
          {:ok, {"https://github.com/octo/repo.git", 0}}

        "/tmp/fake-gh", ["pr", "list" | _args], _opts ->
          {:ok, {"[]", 0}}

        "/tmp/fake-gh", ["pr", "view" | _args], _opts ->
          flunk("ambiguous linked PRs should not be viewed")
      end
    }

    assert {:error, {:ambiguous_linked_pull_requests, ["https://github.com/octo/repo/pull/79", "https://github.com/octo/repo/pull/80"]}} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               ["https://github.com/octo/repo/pull/79", "https://github.com/octo/repo/pull/80"],
               deps
             )
  end

  test "workspace handoff lookup falls back to workspace head sha when linked PR attachments are ambiguous" do
    workspace = "/tmp/owner-workspace-ambiguous-linked-pr-head-sha"
    head_sha = "dddddddddddddddddddddddddddddddddddddddd"
    commit_pulls_path = "/repos/octo/repo/commits/#{head_sha}/pulls"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          case args do
            ["-C", ^workspace, "remote", "get-url", "origin"] -> {:ok, {"https://github.com/octo/repo.git", 0}}
            ["-C", ^workspace, "branch", "--show-current"] -> {:ok, {"workspace-branch\n", 0}}
            ["-C", ^workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] -> {:ok, {"fatal: no upstream\n", 128}}
            ["-C", ^workspace, "rev-parse", "HEAD"] -> {:ok, {head_sha <> "\n", 0}}
          end

        "/tmp/fake-gh", args, _opts ->
          case args do
            ["pr", "list", "--repo", "octo/repo", "--state", _state, "--json", _fields, "--head", _head] ->
              {:ok, {"[]", 0}}

            ["api", "-H", "Accept: application/vnd.github+json", ^commit_pulls_path] ->
              {:ok,
               {Jason.encode!([
                  %{
                    "number" => 81,
                    "html_url" => "https://github.com/octo/repo/pull/81",
                    "head" => %{"ref" => "workspace-branch", "sha" => head_sha},
                    "draft" => false,
                    "mergeable_state" => "clean",
                    "state" => "open"
                  }
                ]), 0}}

            ["pr", "view" | _args] ->
              flunk("ambiguous linked PRs should not be viewed")
          end
      end
    }

    assert {:ok,
            %{
              "number" => 81,
              "__symphonyLookupSource" => "workspace_head_sha",
              "__symphonyExpectedBranch" => "feature/linear",
              "__symphonyMatchedBranch" => "workspace-branch"
            }} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               ["https://github.com/octo/repo/pull/79", "https://github.com/octo/repo/pull/80"],
               deps
             )
  end

  test "workspace handoff lookup rejects draft linked PR attachments" do
    workspace = "/tmp/owner-workspace-draft-linked-pr"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", _args, _opts ->
          {:ok, {"https://github.com/octo/repo.git", 0}}

        "/tmp/fake-gh", ["pr", "list" | _args], _opts ->
          {:ok, {"[]", 0}}

        "/tmp/fake-gh", ["pr", "view", "79" | _args], _opts ->
          {:ok,
           {Jason.encode!(%{
              "number" => 79,
              "url" => "https://github.com/octo/repo/pull/79",
              "headRefName" => "feature/draft",
              "isDraft" => true,
              "mergeStateStatus" => "CLEAN",
              "state" => "OPEN"
            }), 0}}
      end
    }

    assert {:error, {:linked_pull_request_is_draft, 79}} =
             GitHubPrLookup.lookup_workspace_handoff_pr(
               workspace,
               "feature/linear",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )
  end

  test "merged linked pull request lookup returns only merged linked PR attachments" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        send(parent, {:command, :gh, args})

        case args do
          ["pr", "view", "79", "--repo", "octo/repo", "--json", fields] ->
            assert fields == "number,url,headRefName,isDraft,mergeStateStatus,state,mergedAt"

            {:ok,
             {Jason.encode!(%{
                "number" => 79,
                "url" => "https://github.com/octo/repo/pull/79",
                "headRefName" => "feature/done",
                "isDraft" => false,
                "mergeStateStatus" => "UNKNOWN",
                "state" => "MERGED",
                "mergedAt" => "2026-06-09T02:06:42Z"
              }), 0}}
        end
      end
    }

    assert {:ok,
            %{
              "number" => 79,
              "state" => "MERGED",
              "__symphonyLookupSource" => "merged_linked_pull_request"
            }} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )

    assert_received {:command, :gh, ["pr", "view", "79", "--repo", "octo/repo", "--json", _fields]}
  end

  test "merged linked pull request lookup skips open linked PR attachments" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["pr", "view", "79" | _args], _opts ->
        {:ok,
         {Jason.encode!(%{
            "number" => 79,
            "url" => "https://github.com/octo/repo/pull/79",
            "headRefName" => "feature/open",
            "isDraft" => false,
            "mergeStateStatus" => "CLEAN",
            "state" => "OPEN",
            "mergedAt" => nil
          }), 0}}
      end
    }

    assert {:ok, nil} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )
  end

  test "merged linked pull request lookup treats mergedAt as merged evidence" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["pr", "view", "79" | _args], _opts ->
        {:ok,
         {Jason.encode!(%{
            "number" => 79,
            "url" => "https://github.com/octo/repo/pull/79",
            "headRefName" => "feature/merged-at",
            "isDraft" => false,
            "mergeStateStatus" => "UNKNOWN",
            "state" => "CLOSED",
            "mergedAt" => "2026-06-09T02:06:42Z"
          }), 0}}
      end
    }

    assert {:ok, %{"number" => 79, "mergedAt" => "2026-06-09T02:06:42Z"}} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )
  end

  test "merged linked pull request lookup returns nil without linked PR attachments" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        flunk("gh pr view should not run without a linked PR attachment")
      end
    }

    assert {:ok, nil} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/issues/79"],
               deps
             )
  end

  test "merged issue pull request lookup finds merged PR by issue key evidence" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        send(parent, {:command, :gh, args})

        assert args == [
                 "pr",
                 "list",
                 "--repo",
                 "octo/repo",
                 "--state",
                 "merged",
                 "--limit",
                 "50",
                 "--search",
                 "LAB-382",
                 "--json",
                 "number,url,headRefName,isDraft,mergeStateStatus,state,mergedAt,title,body"
               ]

        {:ok,
         {Jason.encode!([
            %{
              "number" => 75,
              "url" => "https://github.com/octo/repo/pull/75",
              "headRefName" => "lab-382-async-review-handoff",
              "isDraft" => false,
              "mergeStateStatus" => "UNKNOWN",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T14:19:59Z",
              "title" => "LAB-382 keep review handoff async",
              "body" => "Refs LAB-382\nLinear: https://linear.app/example/issue/LAB-382/example"
            }
          ]), 0}}
      end
    }

    assert {:ok,
            %{
              "number" => 75,
              "__symphonyLookupSource" => "merged_issue_pull_request",
              "__symphonyMatchedBranch" => "lab-382-async-review-handoff"
            }} =
             GitHubPrLookup.lookup_merged_issue_pull_request(
               "octo/repo",
               "LAB-382",
               "https://linear.app/example/issue/LAB-382/example",
               "lab-382-async-review-handoff",
               deps
             )

    assert_received {:command, :gh, ["pr", "list", "--repo", "octo/repo", "--state", "merged" | _rest]}
  end

  test "merged issue pull request lookup rejects ambiguous issue-key matches" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 75,
              "url" => "https://github.com/octo/repo/pull/75",
              "headRefName" => "lab-382-a",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T14:19:59Z",
              "title" => "LAB-382 first",
              "body" => "Refs LAB-382"
            },
            %{
              "number" => 76,
              "url" => "https://github.com/octo/repo/pull/76",
              "headRefName" => "lab-382-b",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T14:20:59Z",
              "title" => "LAB-382 second",
              "body" => "Refs LAB-382"
            }
          ]), 0}}
      end
    }

    assert {:error, {:ambiguous_merged_issue_pull_requests, ["https://github.com/octo/repo/pull/75", "https://github.com/octo/repo/pull/76"]}} =
             GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", "LAB-382", nil, nil, deps)
  end

  test "merged issue pull request lookup does not match issue key prefixes" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 82,
              "url" => "https://github.com/octo/repo/pull/82",
              "headRefName" => "lab-10-fix",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T17:00:00Z",
              "title" => "LAB-10 fix unrelated issue",
              "body" => "Refs LAB-10"
            }
          ]), 0}}
      end
    }

    assert {:ok, nil} = GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", "LAB-1", nil, nil, deps)
  end

  test "merged issue pull request lookup returns nil without search evidence" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        flunk("lookup without search terms should not call gh")
      end
    }

    assert {:ok, nil} = GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", nil, " ", nil, deps)
  end

  test "merged issue pull request lookup falls through empty search terms" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        search = Enum.at(args, Enum.find_index(args, &(&1 == "--search")) + 1)
        send(parent, {:search, search})

        case search do
          "LAB-382" ->
            {:ok, {Jason.encode!([]), 0}}

          "https://linear.app/example/issue/LAB-382/example" ->
            {:ok,
             {Jason.encode!([
                %{
                  "number" => 77,
                  "url" => "https://github.com/octo/repo/pull/77",
                  "headRefName" => "lab-382-url",
                  "state" => "MERGED",
                  "mergedAt" => "2026-06-09T15:00:00Z",
                  "title" => "URL match",
                  "body" => "Linear: https://linear.app/example/issue/LAB-382/example"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{"number" => 77, "__symphonyLookupSource" => "merged_issue_pull_request"}} =
             GitHubPrLookup.lookup_merged_issue_pull_request(
               "octo/repo",
               "LAB-382",
               "https://linear.app/example/issue/LAB-382/example",
               nil,
               deps
             )

    assert_received {:search, "LAB-382"}
    assert_received {:search, "https://linear.app/example/issue/LAB-382/example"}
  end

  test "merged issue pull request lookup finds branch-only merged PR" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 78,
              "url" => "https://github.com/octo/repo/pull/78",
              "headRefName" => "lab-382-branch",
              "state" => "CLOSED",
              "mergedAt" => "2026-06-09T15:05:00Z",
              "title" => "Branch-only match",
              "body" => ""
            },
            %{
              "number" => 79,
              "url" => "https://github.com/octo/repo/pull/79",
              "headRefName" => "other-branch",
              "state" => "OPEN",
              "mergedAt" => nil,
              "title" => "Not merged",
              "body" => "LAB-382"
            }
          ]), 0}}
      end
    }

    assert {:ok,
            %{
              "number" => 78,
              "__symphonyLookupSource" => "merged_issue_pull_request",
              "__symphonyMatchedBranch" => "lab-382-branch"
            }} =
             GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", nil, nil, "lab-382-branch", deps)
  end

  test "merged issue pull request lookup reports gh command failures" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {"no auth", 4}} end
    }

    assert {:error, {:gh_command_failed, 4}} =
             GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", "LAB-382", nil, nil, deps)
  end

  test "merged issue pull request lookup ignores unmerged and invalid candidates" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            "not a pr",
            %{
              "number" => 80,
              "url" => "https://github.com/octo/repo/pull/80",
              "headRefName" => "lab-382-open",
              "state" => "OPEN",
              "mergedAt" => nil,
              "title" => "LAB-382 not merged",
              "body" => "Refs LAB-382"
            }
          ]), 0}}
      end
    }

    assert {:ok, nil} = GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", "LAB-382", nil, nil, deps)
  end

  test "merged issue pull request lookup reports ambiguous matches without urls" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 81,
              "headRefName" => "lab-382-a",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T16:00:00Z",
              "title" => "LAB-382 first",
              "body" => "Refs LAB-382"
            },
            %{
              "headRefName" => "lab-382-b",
              "state" => "MERGED",
              "mergedAt" => "2026-06-09T16:01:00Z",
              "title" => "LAB-382 second",
              "body" => "Refs LAB-382"
            }
          ]), 0}}
      end
    }

    assert {:error, {:ambiguous_merged_issue_pull_requests, ["81", "(unknown)"]}} =
             GitHubPrLookup.lookup_merged_issue_pull_request("octo/repo", "LAB-382", nil, nil, deps)
  end

  test "merged linked pull request lookup rejects ambiguous linked PR attachments" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        flunk("ambiguous linked PRs should not be viewed")
      end
    }

    assert {:error, {:ambiguous_linked_pull_requests, ["https://github.com/octo/repo/pull/79", "https://github.com/octo/repo/pull/80"]}} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/pull/79", "https://github.com/octo/repo/pull/80"],
               deps
             )
  end

  test "merged linked pull request lookup rejects invalid PR view payloads" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["pr", "view", "79" | _args], _opts ->
        {:ok, {Jason.encode!(%{"number" => 79}), 0}}
      end
    }

    assert {:error, {:invalid_linked_pull_request, %{"number" => 79}}} =
             GitHubPrLookup.lookup_merged_linked_pull_request(
               "octo/repo",
               ["https://github.com/octo/repo/pull/79"],
               deps
             )
  end

  test "resolves repository from SSH host-alias GitHub remote URL" do
    workspace = "/tmp/owner-workspace-alias"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:ok, {"git@github-yakisoba:octo/repo.git", 0}}

        "/tmp/fake-gh", _args, _opts ->
          {:ok,
           {Jason.encode!([%{"number" => 3, "url" => "https://github.com/octo/repo/pull/3", "headRefName" => "feature/alias", "isDraft" => false, "mergeStateStatus" => "CLEAN", "state" => "OPEN"}]),
            0}}
      end
    }

    assert {:ok, %{"number" => 3, "headRefName" => "feature/alias"}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/alias", deps)
  end

  test "returns tagged error for unsupported remote URL" do
    workspace = "/tmp/owner-workspace-unsupported"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:ok, {"https://gitlab.com/octo/repo.git", 0}}

        "/tmp/fake-gh", _args, _opts ->
          flunk("gh should not be invoked when remote URL is unsupported")
      end
    }

    assert {:error, {:unsupported_remote_url, "https://gitlab.com/octo/repo.git"}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/unsupported", deps)
  end

  test "returns tagged error for non-GitHub SSH remote URL" do
    workspace = "/tmp/owner-workspace-ssh-unsupported"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:ok, {"git@gitlab.com:octo/repo.git", 0}}

        "/tmp/fake-gh", _args, _opts ->
          flunk("gh should not be invoked when SSH remote URL is not GitHub")
      end
    }

    assert {:error, {:unsupported_remote_url, "git@gitlab.com:octo/repo.git"}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/unsupported-ssh", deps)
  end

  test "returns error when git is missing" do
    workspace = "/tmp/owner-workspace-no-git"

    deps = %{
      find_git_bin: fn -> nil end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _gh, _args, _opts -> {:error, :unused} end
    }

    assert {:error, :git_not_found} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/no-git", deps)
  end

  test "returns tagged error when git command fails" do
    workspace = "/tmp/owner-workspace-git-fail"

    deps = %{
      find_git_bin: fn -> "/tmp/fake-git" end,
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-git", args, _opts ->
          assert args == ["-C", workspace, "remote", "get-url", "origin"]
          {:error, :git_failed}

        "/tmp/fake-gh", _args, _opts ->
          {:ok, {"[]", 0}}
      end
    }

    assert {:error, {:git_command_failed, :git_failed}} =
             GitHubPrLookup.lookup_workspace_head(workspace, "feature/git-fail", deps)
  end
end
