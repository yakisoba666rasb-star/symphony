defmodule SymphonyElixir.AcceptanceRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AcceptanceRunner

  test "runs up to In Review and emits a markdown report" do
    nonce = "acceptance-test-#{System.unique_integer([:positive])}"
    source_url = "https://github.com/acme/repo/issues/501"
    fetch_agent = start_supervised!({Agent, fn -> 0 end})

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn
        "gh", ["issue", "create" | _args], _opts ->
          {source_url, 0}

        _cmd, _args, _opts ->
          {"", 0}
      end,
      fetch_issues_by_states: fn _states ->
        count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
        {:ok, [issue_for_count(count, nonce, source_url)]}
      end
    }

    assert {:ok, result} =
             AcceptanceRunner.run(
               [
                 repo: "acme/repo",
                 label: "symphony-auto",
                 nonce: nonce,
                 up_to: :in_review,
                 timeout_ms: 1_000,
                 poll_ms: 1
               ],
               deps
             )

    assert result.status == :passed
    assert result.source_issue_url == source_url
    assert Map.has_key?(result.legs, :linear_created)
    assert Map.has_key?(result.legs, :in_review)
    assert result.report =~ "# Symphony Acceptance Report"
    assert result.report =~ "Status: passed"
    assert result.report =~ "pr_exists:"
  end

  defp issue_for_count(count, nonce, source_url) do
    state =
      cond do
        count < 1 -> "Backlog"
        count < 2 -> "Todo"
        count < 4 -> "In Progress"
        true -> "In Review"
      end

    attachments =
      if count >= 3 do
        [source_url, "https://github.com/acme/repo/pull/501"]
      else
        [source_url]
      end

    %SymphonyElixir.Linear.Issue{
      id: "issue-acceptance",
      identifier: "MT-ACCEPTANCE",
      title: "Symphony acceptance #{nonce}",
      description: "Nonce: #{nonce}",
      state: state,
      attachment_urls: attachments
    }
  end
end
