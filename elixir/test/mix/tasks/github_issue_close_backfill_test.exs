defmodule Mix.Tasks.Symphony.GithubIssueCloseBackfillTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Symphony.GithubIssueCloseBackfill
  alias SymphonyElixir.GitHubIssueCloseBackfill, as: BackfillSummary

  test "parses required repo and defaults to dry-run Done state" do
    opts = GithubIssueCloseBackfill.backfill_opts_for_args(["--repo", "octo/repo"])

    assert opts[:repo] == "octo/repo"
    assert opts[:execute] == false
    assert opts[:states] == ["Done"]
  end

  test "parses execute mode and comma-separated states" do
    opts =
      GithubIssueCloseBackfill.backfill_opts_for_args([
        "--repo",
        "octo/repo",
        "--execute",
        "--states",
        "Done, Completed"
      ])

    assert opts[:execute] == true
    assert opts[:states] == ["Done", "Completed"]
  end

  test "parses explicit Linear scope options" do
    opts =
      GithubIssueCloseBackfill.backfill_opts_for_args([
        "--repo",
        "octo/repo",
        "--team-key",
        "LAB",
        "--all-projects",
        "--project-slug",
        "project"
      ])

    assert opts[:team_key] == "LAB"
    assert opts[:all_projects] == true
    assert opts[:project_slug] == "project"
  end

  test "requires repo" do
    assert_raise Mix.Error, ~r/Missing required --repo/, fn ->
      GithubIssueCloseBackfill.backfill_opts_for_args([])
    end
  end

  test "formats dry-run summary with actions and errors" do
    summary = %BackfillSummary{
      inspected: 3,
      candidates: 1,
      already_closed: 1,
      skipped: 1,
      actions: [
        %{issue: "LAB-1", url: "https://github.com/octo/repo/issues/1", status: :would_close, reason: nil}
      ],
      errors: [
        %{
          issue: "LAB-2",
          url: "https://github.com/octo/repo/issues/2",
          status: :error,
          reason: {:closed_at_failed, :rate_limited}
        }
      ]
    }

    output = GithubIssueCloseBackfill.format_summary_for_test(summary, false)

    assert output =~ "GitHub issue close backfill (dry-run)"
    assert output =~ "inspected: 3"
    assert output =~ "- would_close LAB-1 https://github.com/octo/repo/issues/1"
    assert output =~ "- error LAB-2 https://github.com/octo/repo/issues/2: {:closed_at_failed, :rate_limited}"
  end

  test "formats execute summary without optional sections" do
    summary = %BackfillSummary{inspected: 1, candidates: 1, closed: 1}

    output = GithubIssueCloseBackfill.format_summary_for_test(summary, true)

    assert output =~ "GitHub issue close backfill (execute)"
    assert output =~ "closed: 1"
    refute output =~ "Actions"
    refute output =~ "Errors"
  end
end
