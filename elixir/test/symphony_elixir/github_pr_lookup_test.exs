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

  test "looks up PRs by Linear issue key when head branch differs" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn gh, args, _opts ->
        send(parent, {:command, gh, args})

        assert Enum.member?(args, "--search")
        assert Enum.member?(args, "LAB-374 in:title,body")

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
    }

    assert {:ok, %{"number" => 73, "headRefName" => "LAB-374-android-release-config"}} =
             GitHubPrLookup.lookup_by_issue("octo/repo", "LAB-374", deps)

    assert_received {:command, "/tmp/fake-gh", ["pr", "list", "--repo", "octo/repo", "--state", "open" | _]}
  end

  test "issue-key lookup falls back to all states only when no open PR exists" do
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
                  "number" => 72,
                  "url" => "https://github.com/octo/repo/pull/72",
                  "headRefName" => "feature/old-lab-374",
                  "isDraft" => false,
                  "mergeStateStatus" => "CLEAN",
                  "state" => "MERGED"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{"number" => 72, "state" => "MERGED"}} =
             GitHubPrLookup.lookup_by_issue("octo/repo", "LAB-374", deps)

    assert_received {:command, "/tmp/fake-gh", ["pr", "list", "--repo", "octo/repo", "--state", "open" | _]}
    assert_received {:command, "/tmp/fake-gh", ["pr", "list", "--repo", "octo/repo", "--state", "all" | _]}
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
