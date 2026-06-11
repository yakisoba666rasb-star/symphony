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
end
