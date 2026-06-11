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

  test "runs through Done and can match the Linear issue by source attachment only" do
    nonce = "acceptance-done-#{System.unique_integer([:positive])}"
    source_url = "https://github.com/acme/repo/issues/505"
    fetch_agent = start_supervised!({Agent, fn -> 0 end})

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["issue", "create" | _args], _opts -> {:ok, {source_url, 0}} end,
      fetch_issues_by_states: fn _states ->
        count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
        {:ok, [attachment_only_issue_for_count(count, source_url)]}
      end
    }

    assert {:ok, result} =
             AcceptanceRunner.run(
               [
                 repo: "acme/repo",
                 label: "symphony-auto",
                 nonce: nonce,
                 timeout_ms: 1_000,
                 poll_ms: 1
               ],
               deps
             )

    assert result.status == :passed
    assert Map.has_key?(result.legs, :done)
    assert result.report =~ "done:"
  end

  test "restarts after PR exists when requested" do
    nonce = "acceptance-restart-#{System.unique_integer([:positive])}"
    source_url = "https://github.com/acme/repo/issues/502"
    fetch_agent = start_supervised!({Agent, fn -> 0 end})

    restart_agent =
      start_supervised!(%{
        id: {:agent, :acceptance_restart},
        start: {Agent, :start_link, [fn -> [] end]}
      })

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn
        "gh", ["issue", "create" | _args], _opts ->
          {source_url, 0}

        "systemctl", ["restart", "symphony-engine.service"], _opts ->
          fetch_count = Agent.get(fetch_agent, fn count -> count end)
          Agent.update(restart_agent, fn restarts -> [{:restart, fetch_count} | restarts] end)
          {"restarted", 0}

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
                 poll_ms: 1,
                 restart_during_review: true
               ],
               deps
             )

    assert result.status == :passed
    assert [{:restart, restart_fetch_count}] = Agent.get(restart_agent, &Enum.reverse/1)
    assert restart_fetch_count >= 4
    assert not Map.has_key?(result.legs, :done)
  end

  test "returns failed result when a leg times out" do
    nonce = "acceptance-timeout-#{System.unique_integer([:positive])}"
    source_url = "https://github.com/acme/repo/issues/503"

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["issue", "create" | _args], _opts -> {source_url, 0} end,
      fetch_issues_by_states: fn _states ->
        {:ok,
         [
           %SymphonyElixir.Linear.Issue{
             id: "issue-acceptance-timeout",
             identifier: "MT-ACCEPTANCE-TIMEOUT",
             title: "Symphony acceptance #{nonce}",
             description: "Nonce: #{nonce}",
             state: "Backlog",
             attachment_urls: [source_url]
           }
         ]}
      end
    }

    assert {:ok, result} =
             AcceptanceRunner.run(
               [
                 repo: "acme/repo",
                 label: "symphony-auto",
                 nonce: nonce,
                 up_to: :in_review,
                 timeout_ms: 0,
                 poll_ms: 1
               ],
               deps
             )

    assert result.status == :failed
    assert result.failed_leg == :todo
    assert result.report =~ "Status: failed"
    assert result.report =~ "Failed leg: todo"
    assert result.report =~ "done: pending"
  end

  test "validates required repo and label before creating source issue" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn _cmd, _args, _opts -> flunk("command should not run") end,
      fetch_issues_by_states: fn _states -> {:ok, []} end
    }

    assert {:error, :repository_required} =
             AcceptanceRunner.run([repo: " ", label: "symphony-auto"], deps)

    assert {:error, :todo_label_required} =
             AcceptanceRunner.run([repo: "acme/repo", label: nil], deps)

    assert {:error, :repository_required} =
             AcceptanceRunner.run([repo: nil, label: "symphony-auto"], deps)

    assert {:error, :todo_label_required} =
             AcceptanceRunner.run([repo: "acme/repo", label: " "], deps)
  end

  test "returns source issue creation failures" do
    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["issue", "create" | _args], _opts -> {"no label", 1} end,
      fetch_issues_by_states: fn _states -> {:ok, []} end
    }

    assert {:error, {:gh_issue_create_failed, 1, "no label"}} =
             AcceptanceRunner.run([repo: "acme/repo", label: "symphony-auto"], deps)

    deps = %{deps | find_gh_bin: fn -> nil end}
    assert {:error, :gh_not_found} = AcceptanceRunner.run([repo: "acme/repo", label: "symphony-auto"], deps)

    deps = %{
      deps
      | find_gh_bin: fn -> "gh" end,
        run_command: fn "gh", ["issue", "create" | _args], _opts -> {:error, :enoent} end
    }

    assert {:error, {:gh_issue_create_failed, :enoent}} =
             AcceptanceRunner.run([repo: "acme/repo", label: "symphony-auto"], deps)
  end

  test "returns fetch failures while waiting for legs" do
    source_url = "https://github.com/acme/repo/issues/504"

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["issue", "create" | _args], _opts -> {source_url, 0} end,
      fetch_issues_by_states: fn _states -> {:error, :linear_down} end
    }

    assert {:ok, result} =
             AcceptanceRunner.run(
               [repo: "acme/repo", label: "symphony-auto", timeout_ms: 1, poll_ms: 1],
               deps
             )

    assert result.status == :failed
    assert result.failed_leg == :linear_created
    assert result.report =~ "Failed leg: linear_created"
  end

  test "logs restart command failures without failing the acceptance run" do
    for {command_result, command} <- [
          {{"restart denied", 17}, "systemctl restart symphony-engine.service"},
          {{:error, :enoent}, "missing-service restart"}
        ] do
      nonce = "acceptance-restart-failure-#{System.unique_integer([:positive])}"
      source_url = "https://github.com/acme/repo/issues/506"
      fetch_agent = start_supervised!({Agent, fn -> 0 end}, id: {:agent, nonce})

      deps = %{
        find_gh_bin: fn -> "gh" end,
        run_command: fn
          "gh", ["issue", "create" | _args], _opts ->
            {source_url, 0}

          _cmd, _args, _opts ->
            command_result
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
                   up_to: "in_review",
                   timeout_ms: 1_000,
                   poll_ms: 1,
                   restart_during_review: true,
                   restart_command: command
                 ],
                 deps
               )

      assert result.status == :passed
    end
  end

  test "keeps polling when issue is missing or a leg is not reached yet" do
    nonce = "acceptance-polling-#{System.unique_integer([:positive])}"
    source_url = "https://github.com/acme/repo/issues/507"
    fetch_agent = start_supervised!({Agent, fn -> 0 end})

    deps = %{
      find_gh_bin: fn -> "gh" end,
      run_command: fn "gh", ["issue", "create" | _args], _opts -> {source_url, 0} end,
      fetch_issues_by_states: fn _states ->
        count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
        {:ok, polling_issue_for_count(count, nonce, source_url)}
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
    assert Map.has_key?(result.legs, :in_review)
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

  defp polling_issue_for_count(0, _nonce, _source_url), do: []

  defp polling_issue_for_count(count, nonce, source_url) do
    issue =
      %SymphonyElixir.Linear.Issue{
        id: "issue-acceptance-polling",
        identifier: "MT-ACCEPTANCE-POLLING",
        title: "Symphony acceptance #{nonce}",
        description: "Nonce: #{nonce}",
        state: polling_state_for_count(count),
        attachment_urls: polling_attachments_for_count(count, source_url)
      }

    [issue]
  end

  defp polling_state_for_count(count) do
    cond do
      count < 3 -> nil
      count < 4 -> "Todo"
      count < 6 -> "In Progress"
      true -> "In Review"
    end
  end

  defp polling_attachments_for_count(count, source_url) do
    cond do
      count < 5 -> nil
      count < 6 -> [source_url, 123]
      true -> [source_url, 123, "https://github.com/acme/repo/pull/507#ready"]
    end
  end

  defp attachment_only_issue_for_count(count, source_url) do
    state =
      cond do
        count < 1 -> "Backlog"
        count < 2 -> "Todo"
        count < 4 -> "In Progress"
        count < 5 -> "In Review"
        true -> "Done"
      end

    attachments =
      if count >= 3 do
        [source_url, "https://github.com/acme/repo/pull/505?ready=true"]
      else
        [source_url]
      end

    %SymphonyElixir.Linear.Issue{
      id: "issue-acceptance-attachment",
      identifier: "MT-ACCEPTANCE-ATTACHMENT",
      title: "Attachment matched issue",
      description: "No nonce in body",
      state: state,
      attachment_urls: attachments
    }
  end
end
