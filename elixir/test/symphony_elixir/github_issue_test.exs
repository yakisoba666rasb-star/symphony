defmodule SymphonyElixir.GitHubIssueTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubIssue

  defmodule FakeLinearIntakeAdapter do
    def github_issue_synced?(url) do
      send_recipient({:github_issue_synced?, url})
      {:ok, Application.get_env(:symphony_elixir, :github_issue_synced?, false)}
    end

    def find_github_issue_by_description(url) do
      send_recipient({:find_github_issue_by_description, url})
      Application.get_env(:symphony_elixir, :github_intake_description_issue, {:ok, nil})
    end

    def resolve_github_intake_target(team_key, state_name, aliases) do
      send_recipient({:resolve_github_intake_target, team_key, state_name, aliases})

      case Application.get_env(:symphony_elixir, :github_intake_target_result, :ok) do
        :ok ->
          state_id =
            case state_name do
              "Todo" -> "state-todo"
              _ -> "state-backlog"
            end

          {:ok, %{team_id: "team-1", state_id: state_id, project_id: "project-1", project_source: "Symphony"}}

        result ->
          result
      end
    end

    def create_github_backlog_issue(attrs) do
      send_recipient({:create_github_backlog_issue, attrs})

      case Application.get_env(:symphony_elixir, :github_intake_create_result, :ok) do
        :ok -> {:ok, %{"id" => "linear-1", "identifier" => "LAB-900", "url" => "https://linear.app/example/LAB-900"}}
        result -> result
      end
    end

    def create_issue_attachment(issue_id, title, url) do
      send_recipient({:create_issue_attachment, issue_id, title, url})
      Application.get_env(:symphony_elixir, :github_intake_attachment_result, :ok)
    end

    defp send_recipient(message) do
      case Application.get_env(:symphony_elixir, :github_issue_test_recipient) do
        recipient when is_pid(recipient) -> send(recipient, message)
        _ -> :ok
      end
    end
  end

  setup do
    keys = [
      :github_issue_test_recipient,
      :github_issue_synced?,
      :github_intake_description_issue,
      :github_intake_target_result,
      :github_intake_create_result,
      :github_intake_attachment_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1, :__missing__)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :__missing__} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    Application.put_env(:symphony_elixir, :github_issue_test_recipient, self())
    :ok
  end

  test "syncs open GitHub issues into Linear Backlog with attachment dedupe" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        send(self(), {:command, args})

        case args do
          [
            "issue",
            "list",
            "--repo",
            "octo/repo",
            "--state",
            "open",
            "--limit",
            "25",
            "--json",
            "number,title,body,url,labels"
          ] ->
            {:ok,
             {Jason.encode!([
                %{
                  "number" => 67,
                  "title" => "Fix source sync",
                  "body" => "body text",
                  "url" => "https://github.com/octo/repo/issues/67"
                }
              ]), 0}}
        end
      end
    }

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:command,
                     [
                       "issue",
                       "list",
                       "--repo",
                       "octo/repo",
                       "--state",
                       "open",
                       "--limit",
                       "25",
                       "--json",
                       "number,title,body,url,labels"
                     ]}

    assert_received {:github_issue_synced?, "https://github.com/octo/repo/issues/67"}
    assert_received {:find_github_issue_by_description, "https://github.com/octo/repo/issues/67"}
    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}

    assert_received {:create_github_backlog_issue,
                     %{
                       team_id: "team-1",
                       state_id: "state-backlog",
                       project_id: "project-1",
                       title: "Fix source sync",
                       description: "Repo: octo/repo\n\nGitHub Issue: https://github.com/octo/repo/issues/67\n\nbody text"
                     }}

    assert_received {:create_issue_attachment, "linear-1", "GitHub issue #67: Fix source sync", "https://github.com/octo/repo/issues/67"}
  end

  test "sync imports configured label matches into the first active tracker state" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 67,
              "title" => "Promote me",
              "body" => "",
              "url" => "https://github.com/octo/repo/issues/67",
              "labels" => [%{"name" => "Symphony-Auto"}]
            }
          ]), 0}}
      end
    }

    settings =
      intake_settings(%{
        "github_intake" => %{"enabled" => true, "state" => "Backlog", "limit" => 25, "todo_labels" => ["symphony-auto"]}
      })

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter, deps)

    assert_received {:resolve_github_intake_target, "LAB", "Todo", ["Symphony", "repo"]}
    refute_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    assert_received {:create_github_backlog_issue, %{state_id: "state-todo", title: "Promote me"}}
  end

  test "sync keeps unlabeled issues in the configured intake state when todo labels are configured" do
    settings =
      intake_settings(%{
        "github_intake" => %{"enabled" => true, "state" => "Backlog", "limit" => 25, "todo_labels" => ["symphony-auto"]}
      })

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter, single_issue_list_deps())

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    refute_received {:resolve_github_intake_target, "LAB", "Todo", ["Symphony", "repo"]}
    assert_received {:create_github_backlog_issue, %{state_id: "state-backlog"}}
  end

  test "sync matches todo labels exactly without substring matches" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 67,
              "title" => "Not promoted",
              "body" => "",
              "url" => "https://github.com/octo/repo/issues/67",
              "labels" => [%{"name" => "symphony-auto-now"}]
            }
          ]), 0}}
      end
    }

    settings =
      intake_settings(%{
        "github_intake" => %{"enabled" => true, "state" => "Backlog", "limit" => 25, "todo_labels" => ["symphony-auto"]}
      })

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter, deps)

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    refute_received {:resolve_github_intake_target, "LAB", "Todo", ["Symphony", "repo"]}
    assert_received {:create_github_backlog_issue, %{state_id: "state-backlog", title: "Not promoted"}}
  end

  test "sync can import labeled and unlabeled issues into separate states in one repo" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{
              "number" => 67,
              "title" => "Promoted",
              "body" => "",
              "url" => "https://github.com/octo/repo/issues/67",
              "labels" => [%{"name" => "symphony-auto"}]
            },
            %{"number" => 68, "title" => "Backlog", "body" => "", "url" => "https://github.com/octo/repo/issues/68"}
          ]), 0}}
      end
    }

    settings =
      intake_settings(%{
        "github_intake" => %{"enabled" => true, "state" => "Backlog", "limit" => 25, "todo_labels" => ["symphony-auto"]}
      })

    assert {:ok, %{created: 2, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter, deps)

    assert_received {:resolve_github_intake_target, "LAB", "Todo", ["Symphony", "repo"]}
    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    assert_received {:create_github_backlog_issue, %{state_id: "state-todo", title: "Promoted"}}
    assert_received {:create_github_backlog_issue, %{state_id: "state-backlog", title: "Backlog"}}
  end

  test "sync skips GitHub issues that already have Linear attachments" do
    Application.put_env(:symphony_elixir, :github_issue_synced?, true)

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 67, "title" => "Already synced", "body" => "", "url" => "https://github.com/octo/repo/issues/67"}
          ]), 0}}
      end
    }

    assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:github_issue_synced?, "https://github.com/octo/repo/issues/67"}
    refute_received {:create_github_backlog_issue, _attrs}
  end

  test "sync resolves the Linear intake target once per repository" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 67, "title" => "First", "body" => "", "url" => "https://github.com/octo/repo/issues/67"},
            %{"number" => 68, "title" => "Second", "body" => "", "url" => "https://github.com/octo/repo/issues/68"}
          ]), 0}}
      end
    }

    assert {:ok, %{created: 2, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    refute_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
  end

  test "sync does not resolve Linear intake target when a repo has no open issues" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {Jason.encode!([]), 0}} end
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    refute_received {:resolve_github_intake_target, _team, _state, _aliases}
  end

  test "sync repairs existing URL-described Linear issues without creating duplicates" do
    Application.put_env(
      :symphony_elixir,
      :github_intake_description_issue,
      {:ok, %{"id" => "linear-existing", "identifier" => "LAB-901", "url" => "https://linear.app/example/LAB-901"}}
    )

    assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
             sync_single_issue()

    assert_received {:find_github_issue_by_description, "https://github.com/octo/repo/issues/67"}

    assert_received {:create_issue_attachment, "linear-existing", "GitHub issue #67: Fix source sync", "https://github.com/octo/repo/issues/67"}

    refute_received {:create_github_backlog_issue, _attrs}
  end

  test "sync reports existing URL-described Linear issues that cannot be repaired" do
    Application.put_env(:symphony_elixir, :github_intake_description_issue, {:ok, %{"identifier" => "LAB-901"}})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             sync_single_issue()

    Application.put_env(
      :symphony_elixir,
      :github_intake_description_issue,
      {:ok, %{"id" => "linear-existing", "identifier" => "LAB-901"}}
    )

    Application.put_env(:symphony_elixir, :github_intake_attachment_result, {:error, :attachment_down})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             sync_single_issue()
  end

  test "sync reports description fallback lookup failures" do
    Application.put_env(:symphony_elixir, :github_intake_description_issue, {:error, :description_lookup_down})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             sync_single_issue()

    refute_received {:create_github_backlog_issue, _attrs}
  end

  test "sync can self-heal after a previous create succeeded but attachment failed" do
    Application.put_env(:symphony_elixir, :github_intake_attachment_result, {:error, :attachment_down})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             sync_single_issue()

    Application.put_env(
      :symphony_elixir,
      :github_intake_description_issue,
      {:ok, %{"id" => "linear-1", "identifier" => "LAB-900", "url" => "https://linear.app/example/LAB-900"}}
    )

    Application.put_env(:symphony_elixir, :github_intake_attachment_result, :ok)

    assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
             sync_single_issue()

    assert_received {:create_issue_attachment, "linear-1", "GitHub issue #67: Fix source sync", "https://github.com/octo/repo/issues/67"}
  end

  test "sync caches intake failures and skips retry while within ttl" do
    Application.put_env(:symphony_elixir, :github_intake_target_result, {:error, :no_project_match})

    assert {:ok, %{created: 0, skipped: 1, errors: 0}, attempts} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(%{"github_intake" => %{"enabled" => true, "interval_ms" => 1_000, "retry_ttl_ms" => 10_000}}),
               FakeLinearIntakeAdapter,
               %{},
               single_issue_list_deps(1_000)
             )

    assert attempts["https://github.com/octo/repo/issues/67"] == %{
             reason: :no_project_match,
             attempts: 1,
             last_attempt_ms: 1_000
           }

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}

    assert {:ok, %{created: 0, skipped: 1, errors: 0}, ^attempts} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(%{"github_intake" => %{"enabled" => true, "interval_ms" => 1_000, "retry_ttl_ms" => 10_000}}),
               FakeLinearIntakeAdapter,
               attempts,
               single_issue_list_deps(5_000)
             )

    refute_received {:resolve_github_intake_target, _team, _state, _aliases}
    refute_received {:create_github_backlog_issue, _attrs}
  end

  test "sync records retryable target errors in the intake failure cache" do
    Application.put_env(:symphony_elixir, :github_intake_target_result, {:error, :linear_down})

    attempts = %{
      "https://github.com/octo/repo/issues/67" => %{reason: :previous, attempts: 1, last_attempt_ms: 1_000}
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 1}, updated_attempts} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(%{"github_intake" => %{"enabled" => true, "interval_ms" => 1_000, "retry_ttl_ms" => 10_000}}),
               FakeLinearIntakeAdapter,
               attempts,
               single_issue_list_deps(11_000)
             )

    assert updated_attempts["https://github.com/octo/repo/issues/67"] == %{
             reason: :linear_down,
             attempts: 2,
             last_attempt_ms: 11_000
           }
  end

  test "sync retries failed intake after ttl elapses and clears cache on create success" do
    attempts = %{
      "https://github.com/octo/repo/issues/67" => %{reason: :no_project_match, attempts: 1, last_attempt_ms: 1_000}
    }

    assert {:ok, %{created: 1, skipped: 0, errors: 0}, %{}} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(%{"github_intake" => %{"enabled" => true, "interval_ms" => 1_000, "retry_ttl_ms" => 10_000}}),
               FakeLinearIntakeAdapter,
               attempts,
               single_issue_list_deps(11_000)
             )

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    assert_received {:create_github_backlog_issue, _attrs}
  end

  test "sync clears cache on attachment repair success" do
    Application.put_env(
      :symphony_elixir,
      :github_intake_description_issue,
      {:ok, %{"id" => "linear-existing", "identifier" => "LAB-901", "url" => "https://linear.app/example/LAB-901"}}
    )

    attempts = %{
      "https://github.com/octo/repo/issues/67" => %{
        reason: {:github_intake_attachment_repair_failed, :attachment_down},
        attempts: 2,
        last_attempt_ms: 1_000
      }
    }

    assert {:ok, %{created: 0, skipped: 1, errors: 0}, %{}} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(%{"github_intake" => %{"enabled" => true, "interval_ms" => 1_000, "retry_ttl_ms" => 10_000}}),
               FakeLinearIntakeAdapter,
               attempts,
               single_issue_list_deps(11_000)
             )

    assert_received {:create_issue_attachment, "linear-existing", "GitHub issue #67: Fix source sync", "https://github.com/octo/repo/issues/67"}
  end

  test "sync prunes cached failures when a GitHub issue disappears from the open list" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {Jason.encode!([]), 0}} end,
      monotonic_time_ms: fn -> 5_000 end
    }

    attempts = %{
      "https://github.com/octo/repo/issues/67" => %{reason: :no_project_match, attempts: 1, last_attempt_ms: 1_000},
      "https://github.com/other/repo/issues/1" => %{reason: :no_project_match, attempts: 1, last_attempt_ms: 1_000}
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 0}, updated_attempts} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, attempts, deps)

    refute Map.has_key?(updated_attempts, "https://github.com/octo/repo/issues/67")
    assert Map.has_key?(updated_attempts, "https://github.com/other/repo/issues/1")
  end

  test "sync skips GitHub issues when no unique Linear project matches" do
    Application.put_env(:symphony_elixir, :github_intake_target_result, {:error, :no_project_match})

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 67, "title" => "No project", "body" => "", "url" => "https://github.com/octo/repo/issues/67"}
          ]), 0}}
      end
    }

    assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:resolve_github_intake_target, "LAB", "Backlog", ["Symphony", "repo"]}
    refute_received {:create_github_backlog_issue, _attrs}
  end

  test "sync is a no-op when GitHub intake is disabled" do
    settings =
      intake_settings(%{
        "github_intake" => %{"enabled" => false}
      })

    assert {:ok, %{created: 0, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter)

    attempts = %{
      "https://github.com/octo/repo/issues/67" => %{reason: :no_project_match, attempts: 1, last_attempt_ms: 1_000}
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 0}, ^attempts} =
             GitHubIssue.sync_open_issues_to_linear(settings, FakeLinearIntakeAdapter, attempts)
  end

  test "sync returns an adapter capability error before shelling out" do
    deps = %{
      find_gh_bin: fn -> flunk("unsupported adapter should stop before finding gh") end,
      run_command: fn _cmd, _args, _opts -> flunk("unsupported adapter should stop before running gh") end
    }

    assert {:error, {:linear_adapter_missing_github_intake, String}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), String, deps)
  end

  test "sync records repo-level gh list failures as errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {"rate limited", 1}} end
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)
  end

  test "sync skips malformed GitHub issue list items and uses fallback titles" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"title" => "missing url"},
            %{"number" => 68, "title" => "", "body" => nil, "url" => "https://github.com/octo/repo/issues/68"}
          ]), 0}}
      end
    }

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:create_github_backlog_issue,
                     %{
                       title: "GitHub issue",
                       description: "Repo: octo/repo\n\nGitHub Issue: https://github.com/octo/repo/issues/68"
                     }}

    assert_received {:create_issue_attachment, "linear-1", "GitHub issue #68", "https://github.com/octo/repo/issues/68"}
  end

  test "sync treats ambiguous project and create failures as skip or error" do
    Application.put_env(
      :symphony_elixir,
      :github_intake_target_result,
      {:error, {:ambiguous_project_match, [%{id: "project-1"}, %{id: "project-2"}]}}
    )

    deps = single_issue_list_deps()

    assert {:ok, %{created: 0, skipped: 1, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    Application.put_env(:symphony_elixir, :github_intake_target_result, :ok)
    Application.put_env(:symphony_elixir, :github_intake_create_result, {:error, :linear_down})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)
  end

  test "sync returns malformed gh issue list errors at repo level" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {Jason.encode!(%{"not" => "a list"}), 0}} end
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:ok, {"{", 0}} end
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts -> {:error, :enoent} end
    }

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)
  end

  test "sync handles GitHub issue payloads without titles or numbers" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 69, "body" => "", "url" => "https://github.com/octo/repo/issues/69"},
            %{"body" => "", "url" => "https://github.com/octo/repo/issues/70"}
          ]), 0}}
      end
    }

    assert {:ok, %{created: 2, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, deps)

    assert_received {:create_github_backlog_issue, %{title: "GitHub issue #69"}}
    assert_received {:create_issue_attachment, "linear-1", "GitHub issue #69", "https://github.com/octo/repo/issues/69"}
    assert_received {:create_github_backlog_issue, %{title: "GitHub issue"}}
    assert_received {:create_issue_attachment, "linear-1", "GitHub issue", "https://github.com/octo/repo/issues/70"}
  end

  test "sync logs created Linear issues without URL using available labels" do
    Application.put_env(:symphony_elixir, :github_intake_create_result, {:ok, %{"id" => "linear-2", "identifier" => "LAB-902"}})

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(),
               FakeLinearIntakeAdapter,
               single_issue_list_deps()
             )

    Application.put_env(:symphony_elixir, :github_intake_create_result, {:ok, %{"id" => "linear-3"}})

    assert {:ok, %{created: 1, skipped: 0, errors: 0}} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(),
               FakeLinearIntakeAdapter,
               single_issue_list_deps()
             )
  end

  test "sync reports created Linear issues that do not return an id as errors" do
    Application.put_env(:symphony_elixir, :github_intake_create_result, {:ok, %{"identifier" => "LAB-901"}})

    assert {:ok, %{created: 0, skipped: 0, errors: 1}} =
             GitHubIssue.sync_open_issues_to_linear(
               intake_settings(),
               FakeLinearIntakeAdapter,
               single_issue_list_deps()
             )
  end

  test "closes open source issue in the matching repository" do
    parent = self()

    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", args, _opts ->
        send(parent, {:command, args})

        case args do
          ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"] ->
            {:ok, {Jason.encode!(%{"state" => "OPEN"}), 0}}

          ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"] ->
            {:ok, {"closed\n", 0}}
        end
      end
    }

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )

    assert_received {:command, ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"]}
    assert_received {:command, ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"]}
  end

  test "closes open source issue through default runtime dependencies" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-fake-gh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    gh_path = Path.join(tmp_dir, "gh")

    File.write!(gh_path, """
    #!/bin/sh
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      printf '{"state":"OPEN"}'
      exit 0
    fi
    if [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      printf 'closed'
      exit 0
    fi
    exit 2
    """)

    File.chmod!(gh_path, 0o755)

    original_path = System.get_env("PATH", "")
    System.put_env("PATH", tmp_dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf(tmp_dir)
    end)

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR"
             )
  end

  test "accepts raw System.cmd style command tuples" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {Jason.encode!(%{"state" => "OPEN"}), 0}

        "/tmp/fake-gh", ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"], _opts ->
          {"closed\n", 0}
      end
    }

    assert {:ok, :closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "does not close already closed issues" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {:ok, {Jason.encode!(%{"state" => "CLOSED"}), 0}}

        "/tmp/fake-gh", ["issue", "close" | _args], _opts ->
          flunk("already closed issue should not be closed again")
      end
    }

    assert {:ok, :already_closed} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "ignores issue URLs for another repository" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _cmd, _args, _opts ->
        flunk("repo-mismatched issue URL should not call gh")
      end
    }

    assert {:ok, :not_applicable} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/other/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "ignores malformed or missing issue URLs" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn _cmd, _args, _opts ->
        flunk("malformed issue URL should not call gh")
      end
    }

    assert {:ok, :not_applicable} = GitHubIssue.close_if_open("octo/repo", nil, "done via PR", deps)

    assert {:ok, :not_applicable} =
             GitHubIssue.close_if_open("octo/repo", "https://github.com/octo/repo/pull/67", "done via PR", deps)
  end

  test "returns gh lookup errors" do
    deps = %{
      find_gh_bin: fn -> nil end,
      run_command: fn _cmd, _args, _opts ->
        flunk("missing gh binary should stop before running commands")
      end
    }

    assert {:error, :gh_not_found} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns view command failures" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {"not found", 1}}
      end
    }

    assert {:error, {:gh_issue_view_failed, 1, "not found"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns view command runtime errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:error, :enoent}
      end
    }

    assert {:error, {:gh_issue_view_failed, :enoent}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns invalid view payload errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {Jason.encode!(%{"number" => 67}), 0}}
      end
    }

    assert {:error, {:invalid_issue_payload, %{"number" => 67}}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns invalid view json errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {"{", 0}}
      end
    }

    assert {:error, {:gh_json_error, %Jason.DecodeError{}}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns unexpected issue state errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
        {:ok, {Jason.encode!(%{"state" => "MERGED"}), 0}}
      end
    }

    assert {:error, {:unexpected_issue_state, "MERGED"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns close command failures" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {:ok, {Jason.encode!(%{"state" => "OPEN"}), 0}}

        "/tmp/fake-gh", ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"], _opts ->
          {:ok, {"permission denied", 1}}
      end
    }

    assert {:error, {:gh_issue_close_failed, 1, "permission denied"}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  test "returns close command runtime errors" do
    deps = %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn
        "/tmp/fake-gh", ["issue", "view", "67", "--repo", "octo/repo", "--json", "state"], _opts ->
          {:ok, {Jason.encode!(%{"state" => "OPEN"}), 0}}

        "/tmp/fake-gh", ["issue", "close", "67", "--repo", "octo/repo", "--comment", "done via PR"], _opts ->
          {:error, :eacces}
      end
    }

    assert {:error, {:gh_issue_close_failed, :eacces}} =
             GitHubIssue.close_if_open(
               "octo/repo",
               "https://github.com/octo/repo/issues/67",
               "done via PR",
               deps
             )
  end

  defp single_issue_list_deps(now_ms \\ nil) do
    %{
      find_gh_bin: fn -> "/tmp/fake-gh" end,
      run_command: fn "/tmp/fake-gh", _args, _opts ->
        {:ok,
         {Jason.encode!([
            %{"number" => 67, "title" => "Fix source sync", "body" => "", "url" => "https://github.com/octo/repo/issues/67"}
          ]), 0}}
      end,
      monotonic_time_ms: fn -> now_ms || System.monotonic_time(:millisecond) end
    }
  end

  defp sync_single_issue do
    GitHubIssue.sync_open_issues_to_linear(intake_settings(), FakeLinearIntakeAdapter, single_issue_list_deps())
  end

  defp intake_settings(overrides \\ %{}) do
    config =
      %{
        "tracker" => %{"kind" => "linear", "team_key" => "LAB", "api_key" => "token", "all_projects" => true},
        "github_intake" => %{"enabled" => true, "state" => "Backlog", "limit" => 25},
        "repository" => %{
          "default" => "octo/repo",
          "project_routes" => %{"octo/repo" => ["Symphony"]}
        }
      }
      |> Map.merge(overrides)

    {:ok, settings} =
      Schema.parse(config)

    settings
  end
end
