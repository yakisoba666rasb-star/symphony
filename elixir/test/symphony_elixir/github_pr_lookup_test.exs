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

  test "returns the first PR from gh JSON output" do
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
              "mergeStateStatus" => "CLEAN"
            },
            %{
              "number" => 456,
              "url" => "https://github.com/octo/repo/pull/456",
              "headRefName" => "feature/other-branch",
              "isDraft" => true,
              "mergeStateStatus" => "UNKNOWN"
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
             "mergeStateStatus" => "CLEAN"
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
        "all",
        "--json",
        "number,url,headRefName,isDraft,mergeStateStatus",
        "--head",
        "feature/head-branch"
      ]
    }
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
              "mergeStateStatus" => "CLEAN"
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
end
