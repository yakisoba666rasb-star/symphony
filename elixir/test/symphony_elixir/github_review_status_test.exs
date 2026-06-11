defmodule SymphonyElixir.GitHubReviewStatusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubReviewStatus

  test "normalizes changes-requested review status from gh JSON" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/77" | _args], _opts ->
        {Jason.encode!(%{
           "reviewDecision" => "CHANGES_REQUESTED",
           "state" => "OPEN",
           "url" => "https://github.com/acme/repo/pull/77",
           "number" => 77,
           "headRefName" => "feature/rework",
           "latestReviews" => [
             %{"id" => "review-1", "state" => "COMMENTED", "body" => "nit"},
             %{"id" => "review-2", "state" => "CHANGES_REQUESTED", "body" => "fix it"}
           ]
         }), 0}
      end
    }

    assert {:ok, status} = GitHubReviewStatus.view("https://github.com/acme/repo/pull/77", deps)
    assert GitHubReviewStatus.changes_requested?(status)
    assert GitHubReviewStatus.open?(status)
    assert status.latest_changes_requested_review_id == "review-2"
    assert status.changes_requested_body == "fix it"
    assert status.head_ref_name == "feature/rework"
  end

  test "normalizes empty review status and predicates" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/78" | _args], _opts ->
        {Jason.encode!(%{
           "reviewDecision" => nil,
           "state" => "MERGED",
           "url" => "https://github.com/acme/repo/pull/78",
           "number" => 78,
           "headRefName" => nil,
           "latestReviews" => %{"nodes" => []}
         }), 0}
      end
    }

    assert {:ok, status} = GitHubReviewStatus.view("https://github.com/acme/repo/pull/78", deps)
    refute GitHubReviewStatus.changes_requested?(status)
    refute GitHubReviewStatus.open?(status)
    assert status.latest_changes_requested_review_id == nil
    assert status.changes_requested_body == ""
    assert status.head_ref_name == nil
    refute GitHubReviewStatus.open?(%{})
  end

  test "normalizes atom-key review nodes and bodyText" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/82" | _args], _opts ->
        {:ok,
         {Jason.encode!(%{
            "reviewDecision" => "CHANGES_REQUESTED",
            "state" => "OPEN",
            "url" => "https://github.com/acme/repo/pull/82",
            "number" => 82,
            "headRefName" => "feature/atom-review",
            "latestReviews" => %{
              nodes: [
                %{state: "COMMENTED", bodyText: "comment only"},
                %{id: 1234, state: "CHANGES_REQUESTED", bodyText: "body text fix"}
              ]
            }
          }), 0}}
      end
    }

    assert {:ok, status} = GitHubReviewStatus.view("https://github.com/acme/repo/pull/82", deps)
    assert GitHubReviewStatus.changes_requested?(status)
    assert GitHubReviewStatus.open?(status)
    assert status.latest_changes_requested_review_id == "1234"
    assert status.changes_requested_body == "body text fix"
  end

  test "returns gh errors" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/79" | _args], _opts ->
        {"GraphQL error", 1}
      end
    }

    assert {:error, {:gh_pr_view_failed, 1, "GraphQL error"}} =
             GitHubReviewStatus.view("https://github.com/acme/repo/pull/79", deps)

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/83" | _args], _opts ->
        {:error, :enoent}
      end
    }

    assert {:error, {:gh_pr_view_failed, :enoent}} =
             GitHubReviewStatus.view("https://github.com/acme/repo/pull/83", deps)
  end

  test "returns invalid json errors" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["pr", "view", "https://github.com/acme/repo/pull/80" | _args], _opts ->
        {"not json", 0}
      end
    }

    assert {:error, {:invalid_json, message}} =
             GitHubReviewStatus.view("https://github.com/acme/repo/pull/80", deps)

    assert message =~ "unexpected byte"
  end

  test "returns gh not found errors" do
    deps = %{
      find_gh_bin: fn -> nil end,
      run_command: fn _cmd, _args, _opts -> flunk("command should not run") end
    }

    assert {:error, :gh_not_found} = GitHubReviewStatus.view("https://github.com/acme/repo/pull/81", deps)
  end
end
