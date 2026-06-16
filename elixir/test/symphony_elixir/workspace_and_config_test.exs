defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.RepositoryResolver

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace removes failed after_create bootstrap so retry starts fresh" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-failed-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      failed_workspace = Path.join(workspace_root, "MT-FAILED-BOOTSTRAP")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo partial > old.txt && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAILED-BOOTSTRAP")

      refute File.exists?(failed_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git init -b main && echo fresh > README.md"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-FAILED-BOOTSTRAP")
      assert File.dir?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "fresh\n"
      refute File.exists?(Path.join(workspace, "old.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hook receives repository context resolved from issue metadata" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repository-hook-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        repository_default: "yakisoba666rasb-star/symphony",
        hook_after_create: """
        printf '%s' "$SYMPHONY_REPOSITORY" > repo.txt
        printf '%s' "$SYMPHONY_REPOSITORY_OWNER" > owner.txt
        printf '%s' "$SYMPHONY_REPOSITORY_NAME" > name.txt
        printf '%s' "$SYMPHONY_REPOSITORY_CLONE_URL" > clone.txt
        printf '%s' "$SYMPHONY_GITHUB_ISSUE_URL" > source-issue.txt
        """
      )

      issue = %Issue{
        id: "issue-338",
        identifier: "LAB-338",
        title: "Fix stale Tailscale smoke defaults",
        description: """
        Repo: kasotuosawari-design/auto_template
        Source: https://github.com/kasotuosawari-design/auto_template/issues/338
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "repo.txt")) == "kasotuosawari-design/auto_template"
      assert File.read!(Path.join(workspace, "owner.txt")) == "kasotuosawari-design"
      assert File.read!(Path.join(workspace, "name.txt")) == "auto_template"
      assert File.read!(Path.join(workspace, "clone.txt")) == "https://github.com/kasotuosawari-design/auto_template.git"
      assert File.read!(Path.join(workspace, "source-issue.txt")) == "https://github.com/kasotuosawari-design/auto_template/issues/338"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "repository resolver falls back to workflow default and ignores deprecated allowed list" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "allowed" => ["yakisoba666rasb-star/symphony"],
                 "clone_protocol" => "ssh"
               }
             })

    assert {:ok, repository} = RepositoryResolver.resolve(%Issue{identifier: "LAB-1"}, settings)
    assert repository.slug == "yakisoba666rasb-star/symphony"
    assert repository.clone_url == "git@github.com:yakisoba666rasb-star/symphony.git"

    issue = %Issue{
      identifier: "LAB-338",
      description: "https://github.com/kasotuosawari-design/auto_template/issues/338"
    }

    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
  end

  test "repository resolver parses explicit repo hints from string input" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "clone_protocol" => "ssh"
               }
             })

    text = "Repo: kasotuosawari-design/auto_template"

    assert RepositoryResolver.repository_hint?(text)
    assert {:ok, repository} = RepositoryResolver.resolve(text, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
    assert repository.clone_url == "git@github.com:kasotuosawari-design/auto_template.git"
  end

  test "repository resolver extracts GitHub issue URLs from string input" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony"
               }
             })

    text = "See https://github.com/kasotuosawari-design/auto_template/issues/338"

    assert RepositoryResolver.repository_hint?(text)
    assert RepositoryResolver.source_github_issue_url(text) == "https://github.com/kasotuosawari-design/auto_template/issues/338"
    assert {:ok, repository} = RepositoryResolver.resolve(text, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
    assert repository.github_issue_url == "https://github.com/kasotuosawari-design/auto_template/issues/338"
  end

  test "repository resolver extracts labeled GitHub PR source URLs from string input" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony"
               }
             })

    text = "GitHub PR: https://github.com/kasotuosawari-design/auto_template/pull/339"

    assert RepositoryResolver.repository_hint?(text)
    assert RepositoryResolver.source_github_issue_url(text) == "https://github.com/kasotuosawari-design/auto_template/pull/339"
    assert {:ok, repository} = RepositoryResolver.resolve(text, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
    assert repository.github_issue_url == "https://github.com/kasotuosawari-design/auto_template/pull/339"
  end

  test "repository resolver raises for invalid string input through bang API" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony"
               }
             })

    text = """
    See https://github.com/yakisoba666rasb-star/symphony/issues/1
    and https://github.com/kasotuosawari-design/auto_template/issues/338
    """

    assert_raise ArgumentError, ~r/ambiguous_repository_urls/, fn ->
      RepositoryResolver.resolve!(text, settings)
    end
  end

  test "repository resolver normalizes plain map input without treating text as project routes" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "project_routes" => %{
                   "example-org/worker-app" => ["Worker App"]
                 }
               }
             })

    issue = %{
      "title" => "Map input with repository hint",
      "description" => "Repo: kasotuosawari-design/auto_template",
      "attachmentUrls" => ["https://github.com/kasotuosawari-design/auto_template/issues/338"],
      "projectName" => ["Worker App", 123]
    }

    assert {:ok, "example-org/worker-app"} = RepositoryResolver.project_route_slug(issue, settings)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
    assert repository.github_issue_url == "https://github.com/kasotuosawari-design/auto_template/issues/338"
  end

  test "repository resolver keeps project route fallback metadata-based for string input" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "project_routes" => %{
                   "example-org/worker-app" => ["Worker App"]
                 }
               }
             })

    assert RepositoryResolver.project_route_slug("Worker App", settings) == :none
    assert {:ok, repository} = RepositoryResolver.resolve("Worker App", settings)
    assert repository.slug == "yakisoba666rasb-star/symphony"
  end

  test "workflow config supports opt-in GitHub issue intake" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "team_key" => "LAB", "api_key" => "token", "all_projects" => true},
               "github_intake" => %{
                 "enabled" => true,
                 "mirror_labels" => false,
                 "state" => "Backlog",
                 "todo_labels" => ["symphony-auto"],
                 "interval_ms" => 120_000,
                 "retry_ttl_ms" => 240_000,
                 "limit" => 25
               },
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "project_routes" => %{"yakisoba666rasb-star/symphony" => ["Symphony"]}
               }
             })

    assert settings.github_intake.enabled == true
    assert settings.github_intake.mirror_labels == false
    assert settings.github_intake.state == "Backlog"
    assert settings.github_intake.todo_labels == ["symphony-auto"]
    assert settings.github_intake.interval_ms == 120_000
    assert settings.github_intake.retry_ttl_ms == 240_000
    assert settings.github_intake.limit == 25

    assert {:ok, settings} = Schema.parse(%{"github_intake" => %{"enabled" => true, "interval_ms" => 300_000}})
    assert settings.github_intake.mirror_labels == true
    assert settings.github_intake.todo_labels == []
    assert settings.github_intake.retry_ttl_ms == 3_600_000
  end

  test "workflow config rejects invalid GitHub issue intake settings" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "github_intake" => %{
                 "enabled" => true,
                 "state" => "",
                 "interval_ms" => 0,
                 "retry_ttl_ms" => -1,
                 "limit" => 501
               }
             })

    assert message =~ "github_intake"
    assert message =~ "state"
    assert message =~ "interval_ms"
    assert message =~ "retry_ttl_ms"
    assert message =~ "limit"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"github_intake" => %{"enabled" => true, "state" => "   "}})

    assert message =~ "github_intake"
    assert message =~ "state"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"github_intake" => %{"interval_ms" => 120_000, "retry_ttl_ms" => 60_000}})

    assert message =~ "github_intake.retry_ttl_ms must be greater than or equal to interval_ms"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"github_intake" => %{"todo_labels" => ["symphony-auto", " "]}})

    assert message =~ "github_intake"
    assert message =~ "todo_labels"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"github_intake" => %{"todo_labels" => "symphony-auto"}})

    assert message =~ "github_intake"
    assert message =~ "todo_labels"
  end

  test "workflow config supports Done sync interval gating" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.done_sync.interval_ms == 120_000

    assert {:ok, settings} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => 30_000},
               "done_sync" => %{"interval_ms" => 180_000}
             })

    assert settings.done_sync.interval_ms == 180_000
  end

  test "workflow config rejects Done sync interval below polling interval" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => 30_000},
               "done_sync" => %{"interval_ms" => 29_999}
             })

    assert message =~ "done_sync"
    assert message =~ "interval_ms must be greater than or equal to polling.interval_ms"
  end

  test "workflow config defaults Linear terminal states explicitly" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.tracker.terminal_states == [
             "Closed",
             "Cancelled",
             "Canceled",
             "Duplicate",
             "Done"
           ]
  end

  test "workflow config supports review rework interval gating" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.review_rework.interval_ms == 120_000

    assert {:ok, settings} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => 30_000},
               "review_rework" => %{"enabled" => true, "interval_ms" => 180_000}
             })

    assert settings.review_rework.interval_ms == 180_000
  end

  test "workflow config rejects review rework interval below polling interval" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => 30_000},
               "review_rework" => %{"interval_ms" => 29_999}
             })

    assert message =~ "review_rework"
    assert message =~ "interval_ms must be greater than or equal to polling.interval_ms"
  end

  test "workflow config supports stall detection settings" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.stall.enabled == true
    assert settings.stall.threshold_ms == 900_000

    assert {:ok, settings} =
             Schema.parse(%{
               "stall" => %{"enabled" => false, "threshold_ms" => 120_000}
             })

    assert settings.stall.enabled == false
    assert settings.stall.threshold_ms == 120_000
  end

  test "workflow config rejects invalid stall detection settings" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"stall" => %{"threshold_ms" => 0}})

    assert message =~ "stall"
    assert message =~ "threshold_ms"
  end

  test "repository resolver rejects conflicting explicit repo and GitHub source URL" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["yakisoba666rasb-star/symphony", "kasotuosawari-design/auto_template"]
               }
             })

    issue = %Issue{
      identifier: "LAB-CONFLICT",
      description: """
      Repo: yakisoba666rasb-star/symphony
      Source: https://github.com/kasotuosawari-design/auto_template/issues/338
      """
    }

    assert {:error, {:repository_source_conflict, "yakisoba666rasb-star/symphony", "kasotuosawari-design/auto_template"}} =
             RepositoryResolver.resolve(issue, settings)
  end

  test "repository resolver rejects ambiguous GitHub repository URLs without explicit source" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["yakisoba666rasb-star/symphony", "kasotuosawari-design/auto_template"]
               }
             })

    issue = %Issue{
      identifier: "LAB-AMBIGUOUS",
      description: """
      See https://github.com/yakisoba666rasb-star/symphony/issues/1
      and https://github.com/kasotuosawari-design/auto_template/issues/338
      """
    }

    assert {:error, {:ambiguous_repository_urls, ["yakisoba666rasb-star/symphony", "kasotuosawari-design/auto_template"]}} =
             RepositoryResolver.resolve(issue, settings)
  end

  test "repository resolver ignores GitHub advisory URLs as repository hints" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["kasotuosawari-design/orcclaw"]
               }
             })

    issue = %Issue{
      identifier: "LAB-379",
      description: """
      Advisory: https://github.com/advisories/GHSA-jxxr-4gwj-5jf2
      Package: brace-expansion
      """,
      attachment_urls: ["https://github.com/kasotuosawari-design/orcclaw/issues/199"]
    }

    assert RepositoryResolver.repository_hint?(issue)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "kasotuosawari-design/orcclaw"
    assert repository.github_issue_url == "https://github.com/kasotuosawari-design/orcclaw/issues/199"
  end

  test "repository resolver ignores GitHub site route URLs as repository hints" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["kasotuosawari-design/orcclaw"]
               }
             })

    issue = %Issue{
      identifier: "LAB-GITHUB-SITE-LINKS",
      description: """
      Project board: https://github.com/orgs/kasotuosawari-design/projects/1
      Topic: https://github.com/topics/security
      """,
      attachment_urls: ["https://github.com/kasotuosawari-design/orcclaw/issues/199"]
    }

    assert RepositoryResolver.repository_hint?(issue)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "kasotuosawari-design/orcclaw"
    assert repository.github_issue_url == "https://github.com/kasotuosawari-design/orcclaw/issues/199"
  end

  test "repository resolver treats clone URLs and issue URLs for the same repository as one hint" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["ryo1111-qqq/Remote-mouse_v1"]
               }
             })

    issue = %Issue{
      identifier: "LAB-377",
      description: """
      git remote get-url origin -> https://github.com/ryo1111-qqq/Remote-mouse_v1.git
      Related issue: https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/78
      """,
      attachment_urls: ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/78"]
    }

    assert RepositoryResolver.repository_hint?(issue)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "ryo1111-qqq/Remote-mouse_v1"
    assert repository.github_issue_url == "https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/78"
  end

  test "repository resolver canonicalizes explicit repo lines before source consistency checks" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["ryo1111-qqq/Remote-mouse_v1.git"]
               }
             })

    issue = %Issue{
      identifier: "LAB-EXPLICIT-GIT",
      description: """
      Repo: ryo1111-qqq/Remote-mouse_v1.git/
      Source: https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/78?utm_source=linear#note
      """
    }

    assert RepositoryResolver.repository_hint?(issue)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "ryo1111-qqq/Remote-mouse_v1"
    assert repository.github_issue_url == "https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/78"
  end

  test "repository resolver allows explicit repo when reference links mention another repository" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["yakisoba666rasb-star/symphony", "kasotuosawari-design/auto_template"]
               }
             })

    issue = %Issue{
      identifier: "LAB-EXPLICIT",
      description: """
      Repo: kasotuosawari-design/auto_template

      Related design note:
      https://github.com/yakisoba666rasb-star/symphony/issues/1
      """
    }

    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "kasotuosawari-design/auto_template"
  end

  test "repository resolver uses GitHub attachment URLs as metadata hints" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "allowed" => ["ryo1111-qqq/Remote-mouse_v1"]
               }
             })

    issue = %Issue{
      identifier: "LAB-369",
      title: "Bluetooth HID: refresh support after runtime permission result",
      url: "https://linear.app/ryo-work/issue/LAB-369/bluetooth-hid-refresh-support-after-runtime-permission-result",
      attachment_urls: ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/62"]
    }

    assert RepositoryResolver.repository_hint?(issue)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "ryo1111-qqq/Remote-mouse_v1"
    assert repository.github_issue_url == "https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/62"
  end

  test "repository resolver falls back to unique Linear project route before default" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "project_routes" => %{
                   "yakisoba666rasb-star/symphony" => ["Symphony"],
                   "example-org/worker-app" => ["Worker App"]
                 }
               }
             })

    issue = %Issue{
      identifier: "LAB-WORKER",
      title: "Worker app issue without repository hint",
      project_name: "Worker App",
      project_slug: "worker-app"
    }

    assert {:ok, "example-org/worker-app"} = RepositoryResolver.project_route_slug(issue, settings)
    assert {:ok, repository} = RepositoryResolver.resolve(issue, settings)
    assert repository.slug == "example-org/worker-app"
    assert repository.clone_url == "https://github.com/example-org/worker-app.git"
  end

  test "repository resolver rejects ambiguous Linear project route fallback" do
    assert {:ok, settings} =
             Schema.parse(%{
               "repository" => %{
                 "default" => "yakisoba666rasb-star/symphony",
                 "project_routes" => %{
                   "yakisoba666rasb-star/symphony" => ["Symphony"],
                   "example-org/worker-app" => ["Symphony"]
                 }
               }
             })

    issue = %Issue{
      identifier: "LAB-AMBIGUOUS-PROJECT",
      title: "Ambiguous project route issue",
      project_name: "Symphony"
    }

    assert {:error, {:ambiguous_repository_project_routes, project_route_slugs}} =
             RepositoryResolver.project_route_slug(issue, settings)

    assert Enum.sort(project_route_slugs) == ["example-org/worker-app", "yakisoba666rasb-star/symphony"]

    assert {:error, {:ambiguous_repository_project_routes, resolved_slugs}} =
             RepositoryResolver.resolve(issue, settings)

    assert Enum.sort(resolved_slugs) == ["example-org/worker-app", "yakisoba666rasb-star/symphony"]
  end

  test "all-projects dispatch accepts unique project route without GitHub hint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{
        "yakisoba666rasb-star/symphony" => ["symphony", "runtime"],
        "example-org/worker-app" => ["Worker App"]
      }
    )

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), blocked: %{}, max_concurrent_agents: 3}

    remote_issue = %Issue{
      id: "issue-369",
      identifier: "LAB-369",
      title: "Bluetooth HID: refresh support after runtime permission result",
      state: "Todo",
      project_name: "Remote-mouse_v1",
      attachment_urls: ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/62"]
    }

    synced_project_issue = %Issue{
      id: "issue-378",
      identifier: "LAB-378",
      title: "Dedupe Slack handoff text",
      state: "Todo",
      project_name: "orcclaw",
      attachment_urls: ["https://github.com/kasotuosawari-design/orcclaw/issues/197"]
    }

    mismatched_project_issue = %Issue{
      id: "issue-370",
      identifier: "LAB-370",
      title: "Bluetooth HID: track host connection separately from app registration",
      state: "Todo",
      project_name: "Symphony",
      attachment_urls: ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/63"]
    }

    runtime_project_issue = %Issue{
      id: "issue-385",
      identifier: "LAB-385",
      title: "GitHub issue creation should sync to Linear Backlog",
      state: "In Progress",
      project_name: "symphony",
      project_slug: "symphony-afe8a6524892",
      description: "Repo: yakisoba666rasb-star/symphony"
    }

    wrong_project_runtime_issue = %Issue{
      id: "issue-386",
      identifier: "LAB-386",
      title: "GitHub issue creation should sync to Linear Backlog",
      state: "In Progress",
      project_name: "Wrong Project",
      project_slug: "wrong-project",
      description: "Repo: yakisoba666rasb-star/symphony"
    }

    worker_project_worker_issue = %Issue{
      id: "issue-387",
      identifier: "LAB-387",
      title: "Worker app issue",
      state: "In Progress",
      project_name: "Worker App",
      project_slug: "worker-app",
      description: "Repo: example-org/worker-app"
    }

    runtime_project_worker_issue = %Issue{
      id: "issue-388",
      identifier: "LAB-388",
      title: "Worker app issue in runtime project",
      state: "In Progress",
      project_name: "symphony",
      project_slug: "symphony-afe8a6524892",
      description: "Repo: example-org/worker-app"
    }

    unprojected_remote_issue = %Issue{
      id: "issue-372",
      identifier: "LAB-372",
      title: "Server dev extra does not install os input adapter",
      state: "Todo",
      project_name: nil,
      project_slug: nil,
      attachment_urls: ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/74"]
    }

    no_hint_issue = %Issue{
      id: "issue-371",
      identifier: "LAB-371",
      title: "Unlinked project issue",
      state: "Todo",
      project_name: "Symphony",
      project_slug: "symphony-afe8a6524892"
    }

    no_hint_worker_project_issue = %Issue{
      id: "issue-394",
      identifier: "LAB-394",
      title: "Worker issue without repo hint",
      state: "Todo",
      project_name: "Worker App",
      project_slug: "worker-app"
    }

    assert Orchestrator.should_dispatch_issue_for_test(remote_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(synced_project_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(runtime_project_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(worker_project_worker_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(no_hint_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(no_hint_worker_project_issue, state)
    refute Orchestrator.should_dispatch_issue_for_test(unprojected_remote_issue, state)
    refute Orchestrator.should_dispatch_issue_for_test(mismatched_project_issue, state)
    refute Orchestrator.should_dispatch_issue_for_test(wrong_project_runtime_issue, state)
    refute Orchestrator.should_dispatch_issue_for_test(runtime_project_worker_issue, state)
  end

  test "all-projects dispatch rejects ambiguous project routes without GitHub hint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{
        "yakisoba666rasb-star/symphony" => ["Symphony"],
        "example-org/worker-app" => ["Symphony"]
      }
    )

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), blocked: %{}, max_concurrent_agents: 3}

    no_hint_issue = %Issue{
      id: "issue-394",
      identifier: "LAB-394",
      title: "Add regression coverage for issue-key boundary matching",
      state: "Todo",
      project_name: "Symphony",
      project_slug: "symphony-afe8a6524892"
    }

    refute Orchestrator.should_dispatch_issue_for_test(no_hint_issue, state)
  end

  test "auto-assigns missing Linear project from resolved repository unique project match" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{
        "yakisoba666rasb-star/symphony" => ["Symphony"]
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-1", "name" => "auto_template", "slugId" => "auto-template"},
      %{"id" => "project-2", "name" => "Symphony", "slugId" => "symphony-afe8a6524892"}
    ])

    issue = %Issue{
      id: "issue-396",
      identifier: "LAB-396",
      title: "Auto-assign project",
      state: "Todo",
      project_name: nil,
      project_slug: nil,
      attachment_urls: ["https://github.com/yakisoba666rasb-star/symphony/issues/541"]
    }

    assert {:ok, :updated} = SymphonyElixir.Tracker.update_issue_project_from_repository(issue)
    assert_receive {:memory_tracker_fetch_issue_team_projects, "issue-396"}
    assert_receive {:memory_tracker_project_update, "issue-396", "project-2"}
  end

  test "auto-assigns missing Linear project from repository name fallback" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-1", "name" => "auto_template", "slugId" => "auto-template"}
    ])

    issue = %Issue{
      id: "issue-395",
      identifier: "LAB-395",
      title: "Template issue",
      state: "Todo",
      attachment_urls: ["https://github.com/kasotuosawari-design/auto_template/issues/541"]
    }

    assert {:ok, :updated} = SymphonyElixir.Tracker.update_issue_project_from_repository(issue)
    assert_receive {:memory_tracker_project_update, "issue-395", "project-1"}
  end

  test "auto-assign skips ambiguous and missing project matches" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    ambiguous_issue = %Issue{
      id: "issue-ambiguous",
      identifier: "LAB-AMB",
      title: "Ambiguous",
      state: "Todo",
      description: "Repo: example-org/worker-app"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-1", "name" => "Worker App", "slugId" => "worker-app"},
      %{"id" => "project-2", "name" => "worker_app", "slugId" => "worker-app-2"}
    ])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(ambiguous_issue)
      end)

    assert log =~ "multiple matching projects"
    refute_receive {:memory_tracker_project_update, "issue-ambiguous", _}

    no_match_issue = %Issue{
      id: "issue-no-match",
      identifier: "LAB-NO",
      title: "No match",
      state: "Todo",
      description: "Repo: example-org/no-match"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-3", "name" => "Other", "slugId" => "other"}
    ])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(no_match_issue)
      end)

    assert log =~ "no matching project"
    refute_receive {:memory_tracker_project_update, "issue-no-match", _}
  end

  test "auto-assign does not use default repository without an issue repository hint" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-2", "name" => "Symphony", "slugId" => "symphony"}
    ])

    issue = %Issue{
      id: "issue-no-hint",
      identifier: "LAB-NOHINT",
      title: "No repository hint",
      state: "Todo"
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(issue)
      end)

    assert log =~ "no repository hint"
    refute_receive {:memory_tracker_fetch_issue_team_projects, "issue-no-hint"}
    refute_receive {:memory_tracker_project_update, "issue-no-hint", _}
  end

  test "auto-assign skips issues that already have a project or cannot be safely updated" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    projected_issue = %Issue{
      id: "issue-projected",
      identifier: "LAB-PROJECTED",
      title: "Already projected",
      state: "Todo",
      project_name: "Symphony",
      attachment_urls: ["https://github.com/yakisoba666rasb-star/symphony/issues/541"]
    }

    assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(projected_issue)
    refute_receive {:memory_tracker_fetch_issue_team_projects, "issue-projected"}

    missing_id_issue = %Issue{
      id: nil,
      identifier: "LAB-NOID",
      title: "Missing id",
      state: "Todo",
      attachment_urls: ["https://github.com/yakisoba666rasb-star/symphony/issues/541"]
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(missing_id_issue)
      end)

    assert log =~ "issue has no id"
    assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(%{id: "not-an-issue"})
  end

  test "auto-assign skips repository resolution errors and matched projects without ids" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    ambiguous_repo_issue = %Issue{
      id: "issue-repo-ambiguous",
      identifier: "LAB-REPOAMB",
      title: "Ambiguous repo",
      state: "Todo",
      description: """
      https://github.com/example-org/one/issues/1
      https://github.com/example-org/two/issues/2
      """
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} = SymphonyElixir.Tracker.update_issue_project_from_repository(ambiguous_repo_issue)
      end)

    assert log =~ "repository/project lookup failed"

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"name" => "auto_template", "slugId" => "auto-template"}
    ])

    missing_project_id_issue = %Issue{
      id: "issue-project-without-id",
      identifier: "LAB-NOPROJID",
      title: "Project without id",
      state: "Todo",
      attachment_urls: ["https://github.com/kasotuosawari-design/auto_template/issues/541"]
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :skipped} =
                 SymphonyElixir.Tracker.update_issue_project_from_repository(missing_project_id_issue)
      end)

    assert log =~ "matched project has no id"
    refute_receive {:memory_tracker_project_update, "issue-project-without-id", _}
  end

  test "auto-assigned issue is not dispatched in the same poll cycle" do
    previous_projects = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_app_env(:memory_tracker_projects, previous_projects)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_team_key: "LAB",
      tracker_project_slug: nil,
      tracker_all_projects: true,
      repository_default: "yakisoba666rasb-star/symphony",
      repository_project_routes: %{
        "yakisoba666rasb-star/symphony" => ["Symphony"]
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{"id" => "project-2", "name" => "Symphony", "slugId" => "symphony"}
    ])

    issue = %Issue{
      id: "issue-same-cycle",
      identifier: "LAB-SAME",
      title: "Same cycle skip",
      state: "Todo",
      attachment_urls: ["https://github.com/yakisoba666rasb-star/symphony/issues/541"]
    }

    assert [] = Orchestrator.auto_assign_missing_projects_for_test([issue])
    assert_receive {:memory_tracker_project_update, "issue-same-cycle", "project-2"}
  end

  test "config validates explicit repository project routes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      repository_project_routes: %{
        "yakisoba666rasb-star/symphony" => "symphony",
        "example-org/worker-app" => ["Worker App", "worker"]
      }
    )

    assert :ok = Config.validate!()

    assert Config.settings!().repository.project_routes == %{
             "yakisoba666rasb-star/symphony" => "symphony",
             "example-org/worker-app" => ["Worker App", "worker"]
           }

    write_workflow_file!(Workflow.workflow_file_path(), repository_project_routes: "symphony")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "repository.project_routes"

    write_workflow_file!(Workflow.workflow_file_path(),
      repository_project_routes: %{"yakisoba666rasb-star/symphony" => [123]}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "repository.project_routes"
  end

  test "repository schema accepts blank defaults and rejects malformed project route shapes" do
    schema = %Schema.Repository{}

    assert Schema.Repository.changeset(schema, %{
             default: nil,
             project_routes: %{}
           }).valid?

    assert Schema.Repository.changeset(schema, %{default: ""}).valid?

    refute Schema.Repository.changeset(schema, %{
             project_routes: "symphony"
           }).valid?

    refute Schema.Repository.changeset(schema, %{
             project_routes: %{"yakisoba666rasb-star/symphony" => []}
           }).valid?
  end

  test "repository schema validates dynamic route allowed owners" do
    schema = %Schema.Repository{}

    assert Schema.Repository.changeset(schema, %{allowed_owners: []}).valid?
    assert Schema.Repository.changeset(schema, %{allowed_owners: ["yakisoba666rasb-star", "ryo1111-qqq"]}).valid?

    refute Schema.Repository.changeset(schema, %{allowed_owners: "yakisoba666rasb-star"}).valid?
    refute Schema.Repository.changeset(schema, %{allowed_owners: [""]}).valid?
    refute Schema.Repository.changeset(schema, %{allowed_owners: ["bad owner"]}).valid?
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace quarantines existing git workspace with uncommitted changes before recreating" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-dirty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git init -b main && git config user.name Test && git config user.email test@example.com && echo first > README.md && git add README.md && git commit -m initial"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-DIRTY")
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      File.write!(Path.join(workspace, "local-progress.txt"), "untracked\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-DIRTY")
      assert File.read!(Path.join(workspace, "README.md")) == "first\n"
      refute File.exists?(Path.join(workspace, "local-progress.txt"))

      reason_log = Path.join(workspace_root, "MT-DIRTY.dirty-reason.log")
      assert File.exists?(reason_log)
      reason = File.read!(reason_log)
      assert reason =~ "dirty workspace detected"
      assert reason =~ "README.md"
      assert reason =~ "local-progress.txt"
      refute File.exists?(Path.join(workspace, "_reason.log"))

      [quarantined_workspace] =
        workspace_root
        |> Path.join("MT-DIRTY.dirty-*")
        |> Path.wildcard()
        |> Enum.filter(&File.dir?/1)

      assert File.read!(Path.join(quarantined_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(quarantined_workspace, "local-progress.txt")) == "untracked\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace can explicitly resume an existing dirty git workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-dirty-resume-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git init -b main && git config user.name Test && git config user.email test@example.com && echo first > README.md && git add README.md && git commit -m initial"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-DIRTY-RESUME")
      File.write!(Path.join(workspace, "README.md"), "changed\n")
      File.write!(Path.join(workspace, "local-progress.txt"), "untracked\n")

      assert {:ok, ^workspace} =
               Workspace.create_for_issue("MT-DIRTY-RESUME", nil, allow_dirty_existing_workspace: true)

      refute File.exists?(Path.join(workspace_root, "MT-DIRTY-RESUME.dirty-reason.log"))
      assert File.read!(Path.join(workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(workspace, "local-progress.txt")) == "untracked\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace ignores internal review verdict artifact when checking reusable git workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-review-verdict-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git init -b main && git config user.name Test && git config user.email test@example.com && echo first > README.md && git add README.md && git commit -m initial"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-VERDICT")
      File.write!(Path.join(workspace, ".symphony-review-verdict.json"), Jason.encode!(%{"approved_equivalent" => true}))

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-VERDICT")
      refute File.exists?(Path.join(workspace_root, "MT-VERDICT.dirty-reason.log"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace redacts common secret patterns in failed hook logs" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-redaction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf 'LINEAR_API_KEY=lin_secret token=abc123 authorization: bearer ghp_secretvalue\\n' && exit 17"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:workspace_hook_failed, "after_create", 17, output}} =
                   Workspace.create_for_issue("MT-REDACT")

          assert output =~ "lin_secret"
        end)

      assert log =~ "LINEAR_API_KEY=[REDACTED]"
      assert log =~ "token=[REDACTED]"
      assert log =~ "authorization: bearer [REDACTED]"
      refute log =~ "lin_secret"
      refute log =~ "ghp_secretvalue"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup removes only expired dirty quarantine directories" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      expired_dirty = Path.join(workspace_root, "MT-OLD.dirty-20260501-000000")
      fresh_dirty = Path.join(workspace_root, "MT-NEW.dirty-20260525-000000")
      normal_workspace = Path.join(workspace_root, "MT-NORMAL")

      File.mkdir_p!(expired_dirty)
      File.mkdir_p!(fresh_dirty)
      File.mkdir_p!(normal_workspace)
      File.write!(Path.join(expired_dirty, "marker.txt"), "remove")
      File.write!(Path.join(fresh_dirty, "marker.txt"), "keep")
      File.write!(Path.join(normal_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        dirty_workspace_retention_days: 7
      )

      now = ~U[2026-05-26 00:00:00Z]

      assert {:ok, %{removed: [^expired_dirty], kept: kept}} =
               Workspace.cleanup_dirty_workspaces(now: now)

      refute File.exists?(expired_dirty)
      assert File.exists?(fresh_dirty)
      assert File.exists?(normal_workspace)
      assert fresh_dirty in kept
      refute normal_workspace in kept
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup removes expired remote dirty quarantine directories on worker hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-dirty-cleanup-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      local_workspace_root = Path.join(test_root, "local-workspaces")

      File.mkdir_p!(test_root)
      File.mkdir_p!(local_workspace_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: local_workspace_root,
        dirty_workspace_retention_days: 7,
        worker_ssh_hosts: ["worker-01:2200", "worker-02"]
      )

      now = ~U[2026-05-26 00:00:00Z]

      assert {:ok, %{removed: [], kept: []}} = Workspace.cleanup_dirty_workspaces(now: now)

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 -- worker-01 bash -lc"
      assert trace =~ "-- worker-02 bash -lc"
      assert trace =~ local_workspace_root
      assert trace =~ "20260519-000000"
      assert trace =~ ~s(for dirty_workspace in "$root"/*.dirty-*; do)
      assert trace =~ ~s([[ "${BASH_REMATCH[1]}" < "$cutoff" ]])
      assert trace =~ ~s(rm -rf -- "$dirty_workspace")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "project" => %{
        "name" => "Remote-mouse_v1",
        "slugId" => "remote-mouse-v1-a61ad84f7ad0"
      },
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "attachments" => %{
        "nodes" => [
          %{"url" => "https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/62"},
          %{"url" => nil}
        ]
      },
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.project_name == "Remote-mouse_v1"
    assert issue.project_slug == "remote-mouse-v1-a61ad84f7ad0"
    assert issue.attachment_urls == ["https://github.com/ryo1111-qqq/Remote-mouse_v1/issues/62"]
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  for terminal_state <- ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"] do
    @terminal_state terminal_state

    test "terminal Linear state #{@terminal_state} is not dispatch-eligible" do
      state = %Orchestrator.State{
        max_concurrent_agents: 3,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: "terminal-#{@terminal_state}",
        identifier: "MT-#{String.upcase(@terminal_state)}",
        title: "Terminal work",
        state: @terminal_state
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "dispatch revalidation skips issue refreshed in terminal Linear state #{@terminal_state}" do
      stale_issue = %Issue{
        id: "terminal-revalidation-#{@terminal_state}",
        identifier: "MT-TERMINAL-#{String.upcase(@terminal_state)}",
        title: "Stale terminal work",
        state: "Todo"
      }

      refreshed_issue = %Issue{
        stale_issue
        | state: @terminal_state
      }

      fetcher = fn [issue_id] ->
        assert issue_id == stale_issue.id
        {:ok, [refreshed_issue]}
      end

      assert {:skip, ^refreshed_issue} =
               Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
    end
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "claiming a Todo issue transitions it to In Progress before dispatch" do
    issue = %Issue{
      id: "claim-1",
      identifier: "MT-CLAIM",
      title: "Claim before work",
      state: "Todo"
    }

    parent = self()

    updater = fn issue_id, state_name ->
      send(parent, {:claim_update, issue_id, state_name})
      :ok
    end

    assert {:ok, %Issue{state: "In Progress"}} =
             Orchestrator.claim_issue_for_dispatch_for_test(issue, updater)

    assert_receive {:claim_update, "claim-1", "In Progress"}
  end

  test "claim failure is returned before worker dispatch can start" do
    issue = %Issue{
      id: "claim-fails-1",
      identifier: "MT-CLAIM-FAIL",
      title: "Claim failure",
      state: "Todo"
    }

    updater = fn "claim-fails-1", "In Progress" -> {:error, :linear_down} end

    assert {:error, {:claim_issue_failed, :linear_down}} =
             Orchestrator.claim_issue_for_dispatch_for_test(issue, updater)
  end

  test "claiming an already active non-Todo issue does not update Linear" do
    issue = %Issue{
      id: "claim-in-progress-1",
      identifier: "MT-CLAIM-IP",
      title: "Already claimed",
      state: "In Progress"
    }

    updater = fn _issue_id, _state_name -> flunk("unexpected state update") end

    assert {:ok, ^issue} = Orchestrator.claim_issue_for_dispatch_for_test(issue, updater)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a", "-oProxyCommand=touch /tmp/nope"])
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.ssh_hosts"

    write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a", 123])
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.ssh_hosts"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      repository_project_routes: %{"symphony" => ["runtime"]}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "repository.project_routes"

    write_workflow_file!(Workflow.workflow_file_path(),
      repository_project_routes: %{"yakisoba666rasb-star/symphony" => [""]}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "repository.project_routes"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "config parses review handoff and role runner settings" do
    current_model = Config.current_codex_model()

    workflow = """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
      review_state: Legacy Review
    agent:
      max_review_fix_loops: 2
    review:
      final_review: human_required
      handoff_state: In Review
      require_pr_url_before_handoff: true
      approve_equivalent_required_before_handoff: true
      merge_decision: human_required_after_approve_equivalent
      auto_merge: false
      max_review_fix_loops: 5
      implementer_model: #{current_model}
      implementer_profile: implementer
      reviewer_model: #{current_model}
      reviewer_profile: reviewer
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    config = Config.settings!()
    assert config.review.final_review == "human_required"
    assert config.review.handoff_state == "In Review"
    assert config.review.require_pr_url_before_handoff == true
    assert config.review.approve_equivalent_required_before_handoff == true
    assert config.review.merge_decision == "human_required_after_approve_equivalent"
    assert config.review.auto_merge == false
    assert Config.review_handoff_state() == "In Review"
    assert Config.max_review_fix_loops() == 5

    assert Config.review_role_codex_options(:implementer) == [
             codex_command: "codex --config 'model=\"#{current_model}\"' --profile 'implementer' app-server"
           ]

    assert Config.review_role_codex_options(:reviewer) == [
             codex_command: "codex --config 'model=\"#{current_model}\"' --profile 'reviewer' app-server"
           ]
  end

  test "config parses review workflow from x-lab-runtime" do
    current_model = Config.current_codex_model()

    workflow = """
    ---
    review:
      final_review: gpt
      max_review_fix_loops: 1
    x-lab-runtime:
      review_workflow:
        final_review: human_required
        handoff_state: In Review
        require_pr_url_before_handoff: true
        approve_equivalent_required_before_handoff: true
        merge_decision: human_required_after_approve_equivalent
        auto_merge: false
        max_review_fix_loops: 7
        implementer_model: #{current_model}
        implementer_profile: implementer
        reviewer_model: #{current_model}
        reviewer_profile: reviewer
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    config = Config.settings!()
    assert config.review.final_review == "human_required"
    assert config.review.handoff_state == "In Review"
    assert config.review.require_pr_url_before_handoff == true
    assert config.review.approve_equivalent_required_before_handoff == true
    assert config.review.merge_decision == "human_required_after_approve_equivalent"
    assert config.review.auto_merge == false
    assert Config.max_review_fix_loops() == 7

    assert Config.review_role_codex_options(:implementer) == [
             codex_command: "codex --config 'model=\"#{current_model}\"' --profile 'implementer' app-server"
           ]

    assert Config.review_role_codex_options(:reviewer) == [
             codex_command: "codex --config 'model=\"#{current_model}\"' --profile 'reviewer' app-server"
           ]
  end

  test "blocked issue comment defaults to English and supports workflow override" do
    assert Config.blocked_issue_comment("LAB-1", "missing PR") ==
             "Symphony blocked LAB-1.\n\nReason: missing PR"

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    review:
      blocked_comment_template: |
        {{ identifier }} を停止しました。

        理由: {{ reason }}
    ---
    """)

    assert Config.blocked_issue_comment("LAB-2", "PRなし") ==
             "LAB-2 を停止しました。\n\n理由: PRなし"
  end

  test "config rejects retired Codex models in runtime command and review roles" do
    [retired_model | _] = Config.retired_codex_models()

    workflow = """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    codex:
      command: codex --config 'model="#{retired_model}"' app-server
    review:
      implementer_model: #{retired_model}
      reviewer_command: codex --config 'model="#{retired_model}"' --profile reviewer app-server
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert {:error, {:retired_codex_model, message}} = Config.validate!()
    assert message =~ retired_model
    assert message =~ "codex.command"
    assert message =~ "review.implementer_model"
    assert message =~ "review.reviewer_command"
  end

  test "schema rejects unsupported review workflow policies" do
    assert {
             :error,
             {:invalid_workflow_config, message}
           } =
             Schema.parse(%{
               "x-lab-runtime" => %{
                 "review_workflow" => %{
                   "final_review" => "automated",
                   "require_pr_url_before_handoff" => false,
                   "approve_equivalent_required_before_handoff" => false,
                   "merge_decision" => "always_auto_merge",
                   "auto_merge" => true
                 }
               }
             })

    assert message =~ "review.final_review is invalid"
    assert message =~ "review.require_pr_url_before_handoff must be true"
    assert message =~ "review.approve_equivalent_required_before_handoff must be true"
    assert message =~ "review.merge_decision is invalid"
    assert message =~ "review.auto_merge must be false"
  end

  test "schema rejects malformed x-lab-runtime.review_workflow" do
    assert {
             :error,
             {:invalid_workflow_config, message}
           } =
             Schema.parse(%{
               "x-lab-runtime" => %{"review_workflow" => true}
             })

    assert message =~ "x-lab-runtime.review_workflow must be an object"
  end

  test "schema rejects review collision when review is not an object" do
    assert {
             :error,
             {:invalid_workflow_config, message}
           } =
             Schema.parse(%{
               "review" => "human_required",
               "x-lab-runtime" => %{"review_workflow" => %{"final_review" => "human_required"}}
             })

    assert message =~ "x-lab-runtime.review_workflow requires review to be a map"
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "relative workspace root resolves against selected WORKFLOW.md directory for local use" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-relative-workflow-root-#{System.unique_integer([:positive])}"
      )

    try do
      workflow_dir = Path.join(test_root, "project")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")
      expected_root = Path.join(workflow_dir, "workspaces")

      File.mkdir_p!(workflow_dir)
      File.mkdir_p!(expected_root)

      write_workflow_file!(workflow_file, workspace_root: "workspaces")
      Workflow.set_workflow_file_path(workflow_file)

      assert Config.settings!().workspace.root == "workspaces"
      assert Config.local_workspace_root!() == expected_root
      refute Config.local_workspace_root!() == Path.expand("workspaces")

      assert {:ok, default_runtime_policy} = Config.codex_runtime_settings(nil)

      assert default_runtime_policy.turn_sandbox_policy["writableRoots"] == [
               expected_root
             ]

      assert {:ok, workspace} = Workspace.create_for_issue("LAB-418-RELATIVE")
      assert workspace == Path.join(expected_root, "LAB-418-RELATIVE")
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace creation quarantines existing dirty git workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-dirty-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-DIRTY"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\n' "$*" >> "$trace_file"

      printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-DIRTY", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "quarantine_workspace"
      assert trace =~ ".dirty-$(date -u +%Y%m%d-%H%M%S)"
      assert trace =~ ~s(mv "$workspace" "$quarantine_workspace")
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace creation can explicitly resume existing dirty git workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-dirty-resume-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-DIRTY-RESUME"
      dirty_status = " M README.md\n?? local-progress.txt\n"
      escaped_dirty_status = String.replace(dirty_status, "\n", "\\n")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\n' "$*" >> "$trace_file"

      case "$*" in
        *"allow_dirty_existing_workspace"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '0' '#{workspace_path}'
          exit 0
          ;;
      esac

      printf '%s\\t%s\\t%s\\n' '__SYMPHONY_DIRTY_WORKSPACE__' '#{workspace_path}' '#{escaped_dirty_status}'
      exit 72
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"]
      )

      assert {:ok, ^workspace_path} =
               Workspace.create_for_issue("MT-SSH-DIRTY-RESUME", "worker-01:2200", allow_dirty_existing_workspace: true)

      trace = File.read!(trace_file)
      assert trace =~ "allow_dirty_existing_workspace"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace remove rejects unsafe paths before hooks or deletion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-remove-safety-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_remove: "echo before-remove"
      )

      unsafe_workspaces = [
        "",
        workspace_root,
        "/tmp/outside-workspace-root",
        "~/.symphony-remote-workspaces/../outside-workspace-root",
        "~/.symphony-remote-workspaces/bad\nname",
        "~/.symphony-remote-workspaces/bad" <> <<0>> <> "name"
      ]

      Enum.each(unsafe_workspaces, fn unsafe_workspace ->
        assert {:error, _reason, ""} = Workspace.remove(unsafe_workspace, "worker-01:2200")
      end)

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 -- worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
