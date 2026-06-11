defmodule SymphonyElixir.ZeroTouchEvidenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ZeroTouchEvidence

  defmodule FakeTracker do
    def fetch_zero_touch_evidence("intake-issue") do
      {:ok,
       %{
         attachments: [
           %{
             "url" => "https://github.com/octo/repo/issues/67",
             "title" => "GitHub issue #67",
             "createdAt" => "2026-06-11T00:00:00Z"
           }
         ],
         history: [
           %{"toState" => %{"name" => "In Progress"}, "createdAt" => "2026-06-11T00:05:00Z"},
           %{"toState" => %{"name" => "In Review"}, "createdAt" => "2026-06-11T00:20:00Z"},
           %{"toState" => %{"name" => "Done"}, "createdAt" => "2026-06-11T00:45:00Z"}
         ],
         comments: []
       }}
    end

    def fetch_zero_touch_evidence("duplicate-issue") do
      {:ok,
       %{
         attachments: [%{"url" => "https://github.com/octo/repo/issues/67"}],
         history: [],
         comments: [%{"body" => ZeroTouchEvidence.marker()}]
       }}
    end

    def fetch_zero_touch_evidence("non-intake-issue") do
      {:ok,
       %{
         attachments: [%{"url" => "https://github.com/octo/repo/pull/67"}],
         history: [],
         comments: []
       }}
    end

    def create_comment(issue_id, body) do
      send(self(), {:created_comment, issue_id, body})
      :ok
    end
  end

  defmodule FakeGitHubIssue do
    def closed_at("octo/repo", "https://github.com/octo/repo/issues/67") do
      {:ok, "2026-06-11T00:46:00Z"}
    end
  end

  defmodule FakeTrackerError do
    def fetch_zero_touch_evidence(_issue_id), do: {:error, :linear_down}
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerUnexpected do
    def fetch_zero_touch_evidence(_issue_id), do: :unexpected
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerRaise do
    def fetch_zero_touch_evidence(_issue_id), do: raise("boom")
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeTrackerUnsupported do
    def create_comment(_issue_id, _body), do: :ok
  end

  defmodule FakeGitHubIssueError do
    def closed_at("octo/repo", "https://github.com/octo/repo/issues/67"), do: {:error, :rate_limited}
  end

  defmodule FakeGitHubIssueUnexpected do
    def closed_at("octo/repo", "https://github.com/octo/repo/issues/67"), do: :unexpected
  end

  test "detects GitHub issue intake origin from attachments" do
    assert ZeroTouchEvidence.intake_origin?(%{
             attachments: [%{"url" => "https://github.com/octo/repo/issues/67"}]
           })

    refute ZeroTouchEvidence.intake_origin?(%{
             attachments: [%{"url" => "https://github.com/octo/repo/pull/67"}]
           })
  end

  test "composes full evidence comment timeline" do
    issue = %Issue{id: "intake-issue", identifier: "LAB-403"}

    body =
      ZeroTouchEvidence.compose_comment(
        issue,
        %{
          attachments: [
            %{"url" => "https://github.com/octo/repo/issues/67", "createdAt" => "2026-06-11T00:00:00Z"}
          ],
          history: [
            %{"toState" => %{"name" => "In Progress"}, "createdAt" => "2026-06-11T00:05:00Z"},
            %{"toState" => %{"name" => "In Review"}, "createdAt" => "2026-06-11T00:20:00Z"},
            %{"toState" => %{"name" => "Done"}, "createdAt" => "2026-06-11T00:45:00Z"}
          ],
          comments: []
        },
        %{
          "url" => "https://github.com/octo/repo/pull/68",
          "createdAt" => "2026-06-11T00:10:00Z",
          "mergedAt" => "2026-06-11T00:40:00Z"
        },
        "https://github.com/octo/repo/issues/67",
        "2026-06-11T00:46:00Z"
      )

    assert body =~ ZeroTouchEvidence.marker()
    assert body =~ "- intake_at: 2026-06-11T00:00:00Z"
    assert body =~ "- dispatched_at: 2026-06-11T00:05:00Z"
    assert body =~ "- pr_created_at: 2026-06-11T00:10:00Z"
    assert body =~ "- in_review_at: 2026-06-11T00:20:00Z"
    assert body =~ "- merged_at: 2026-06-11T00:40:00Z"
    assert body =~ "- done_at: 2026-06-11T00:45:00Z"
    assert body =~ "- source_closed_at: 2026-06-11T00:46:00Z"
  end

  test "partial data renders n/a instead of crashing" do
    body =
      ZeroTouchEvidence.compose_comment(
        %Issue{id: "intake-issue", identifier: "LAB-403"},
        %{attachments: [%{"url" => "https://github.com/octo/repo/issues/67"}], history: [], comments: []},
        %{},
        "https://github.com/octo/repo/issues/67",
        nil
      )

    assert body =~ "- intake_at: n/a"
    assert body =~ "- dispatched_at: n/a"
    assert body =~ "- pr_created_at: n/a"
    assert body =~ "- in_review_at: n/a"
    assert body =~ "- merged_at: n/a"
    assert body =~ "- done_at: n/a"
    assert body =~ "- source_closed_at: n/a"
  end

  test "normalizes nested evidence shapes and date values" do
    body =
      ZeroTouchEvidence.compose_comment(
        %Issue{id: "intake-issue", identifier: "LAB-403"},
        %{
          "issue" => %{
            "attachments" => %{
              "nodes" => [
                %{
                  "url" => "https://github.com/octo/repo/issues/67",
                  "createdAt" => "2026-06-11T00:00:00Z"
                }
              ]
            },
            "history" => %{"nodes" => [%{"toState" => %{"name" => "Queued"}, "createdAt" => "ignored"}]},
            "comments" => %{"nodes" => [%{"body" => 123}]}
          }
        },
        %{"url" => "https://github.com/octo/repo/pull/68"},
        "https://github.com/octo/repo/issues/67",
        nil
      )

    assert body =~ "- intake_at: 2026-06-11T00:00:00Z"
    assert body =~ "- dispatched_at: n/a"
    assert body =~ "- done_at: n/a"
    refute ZeroTouchEvidence.evidence_comment_exists?(%{"comments" => [%{"body" => 123}]})
  end

  test "normalizes alternate atom relation nodes" do
    evidence = %{
      issue: %{
        attachments: %{nodes: [%{url: "https://github.com/octo/repo/issues/67"}]},
        history: %{nodes: []},
        comments: %{nodes: []}
      }
    }

    assert ZeroTouchEvidence.intake_origin?(evidence)
    assert ZeroTouchEvidence.source_issue_url(evidence) == "https://github.com/octo/repo/issues/67"
  end

  test "normalizes top-level string keys and malformed evidence values" do
    assert ZeroTouchEvidence.intake_origin?(%{
             "attachments" => [%{"url" => "https://github.com/octo/repo/issues/67"}]
           })

    refute ZeroTouchEvidence.intake_origin?(%{"attachments" => [123]})
    refute ZeroTouchEvidence.intake_origin?(%{})
    refute ZeroTouchEvidence.evidence_comment_exists?(%{comments: [123]})
    refute ZeroTouchEvidence.evidence_comment_exists?(%{})

    assert ZeroTouchEvidence.source_issue_url(%{
             issue: %{attachments: [%{"url" => "https://github.com/octo/repo/issues/67"}]}
           }) == "https://github.com/octo/repo/issues/67"

    body =
      ZeroTouchEvidence.compose_comment(
        %Issue{id: "intake-issue"},
        %{
          issue: %{
            attachments: %{nodes: []},
            history: %{nodes: [%{"toState" => 123, "createdAt" => "ignored"}]},
            comments: %{nodes: []}
          }
        },
        %{"url" => ""},
        "",
        nil
      )

    assert body =~ "Issue: intake-issue"
    assert body =~ "Pull request: n/a"
    assert body =~ "- dispatched_at: n/a"
  end

  test "posting is idempotent and skips non-intake issues" do
    pr = %{"url" => "https://github.com/octo/repo/pull/68", "createdAt" => "2026-06-11T00:10:00Z"}

    assert :ok =
             ZeroTouchEvidence.maybe_post_after_done(
               %Issue{id: "duplicate-issue", identifier: "LAB-403"},
               "octo/repo",
               pr,
               FakeTracker,
               FakeGitHubIssue
             )

    assert :ok =
             ZeroTouchEvidence.maybe_post_after_done(
               %Issue{id: "non-intake-issue", identifier: "LAB-404"},
               "octo/repo",
               pr,
               FakeTracker,
               FakeGitHubIssue
             )

    refute_receive {:created_comment, _, _}
  end

  test "posts one comment for intake-originated done issue" do
    pr = %{
      "url" => "https://github.com/octo/repo/pull/68",
      "createdAt" => "2026-06-11T00:10:00Z",
      "mergedAt" => "2026-06-11T00:40:00Z"
    }

    assert :ok =
             ZeroTouchEvidence.maybe_post_after_done(
               %Issue{id: "intake-issue", identifier: "LAB-403"},
               "octo/repo",
               pr,
               FakeTracker,
               FakeGitHubIssue
             )

    assert_receive {:created_comment, "intake-issue", body}
    assert body =~ ZeroTouchEvidence.marker()
    assert body =~ "Source GitHub issue: https://github.com/octo/repo/issues/67"
    assert body =~ "- source_closed_at: 2026-06-11T00:46:00Z"
    refute_receive {:created_comment, _, _}
  end

  test "closed-at lookup failures render n/a without blocking comment" do
    pr = %{"url" => "https://github.com/octo/repo/pull/68", "mergedAt" => "2026-06-11T00:40:00Z"}

    log =
      capture_log(fn ->
        assert :ok =
                 ZeroTouchEvidence.maybe_post_after_done(
                   %Issue{id: "intake-issue", identifier: "LAB-403"},
                   "octo/repo",
                   pr,
                   FakeTracker,
                   FakeGitHubIssueError
                 )
      end)

    assert log =~ "source_closed_at"
    assert_receive {:created_comment, "intake-issue", body}
    assert body =~ "- source_closed_at: n/a"
  end

  test "unexpected closed-at lookup result renders n/a" do
    pr = %{"url" => "https://github.com/octo/repo/pull/68"}

    assert :ok =
             ZeroTouchEvidence.maybe_post_after_done(
               %Issue{id: "intake-issue", identifier: "LAB-403"},
               "octo/repo",
               pr,
               FakeTracker,
               FakeGitHubIssueUnexpected
             )

    assert_receive {:created_comment, "intake-issue", body}
    assert body =~ "- source_closed_at: n/a"
  end

  test "fetch errors, unexpected results, exceptions, and invalid inputs do not crash done sync" do
    issue = %Issue{id: "intake-issue", identifier: "LAB-403"}
    pr = %{"url" => "https://github.com/octo/repo/pull/68"}

    assert capture_log(fn ->
             assert {:error, :linear_down} =
                      ZeroTouchEvidence.maybe_post_after_done(
                        issue,
                        "octo/repo",
                        pr,
                        FakeTrackerError,
                        FakeGitHubIssue
                      )
           end) =~ "linear_down"

    assert capture_log(fn ->
             assert {:error, :unexpected} =
                      ZeroTouchEvidence.maybe_post_after_done(
                        issue,
                        "octo/repo",
                        pr,
                        FakeTrackerUnexpected,
                        FakeGitHubIssue
                      )
           end) =~ "unexpected"

    assert capture_log(fn ->
             assert {:error, {:exception, "boom"}} =
                      ZeroTouchEvidence.maybe_post_after_done(
                        issue,
                        "octo/repo",
                        pr,
                        FakeTrackerRaise,
                        FakeGitHubIssue
                      )
           end) =~ "boom"

    assert :ok =
             ZeroTouchEvidence.maybe_post_after_done(
               issue,
               "octo/repo",
               pr,
               FakeTrackerUnsupported,
               FakeGitHubIssue
             )

    assert :ok = ZeroTouchEvidence.maybe_post_after_done(:bad, "octo/repo", pr, FakeTracker, FakeGitHubIssue)
  end
end
