defmodule SymphonyElixir.RepositoryRoutesTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RepositoryResolver, RepositoryRoutes}

  defmodule FakeLinearProjectClient do
    def graphql(query, %{teamKey: "LAB", first: 250}) do
      send_recipient({:team_projects_query, String.contains?(query, "externalLinks("), String.contains?(query, "links(")})

      case Application.get_env(:symphony_elixir, :repository_routes_error) do
        nil ->
          {:ok,
           %{
             "data" => %{
               "teams" => %{
                 "nodes" => [
                   %{
                     "projects" => %{
                       "nodes" => Application.get_env(:symphony_elixir, :repository_routes_projects, [])
                     }
                   }
                 ]
               }
             }
           }}

        reason ->
          {:error, reason}
      end
    end

    defp send_recipient(message) do
      case Application.get_env(:symphony_elixir, :repository_routes_test_recipient) do
        recipient when is_pid(recipient) -> send(recipient, message)
        _ -> :ok
      end
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module, :__missing__)
    previous_projects = Application.get_env(:symphony_elixir, :repository_routes_projects, :__missing__)
    previous_error = Application.get_env(:symphony_elixir, :repository_routes_error, :__missing__)
    previous_recipient = Application.get_env(:symphony_elixir, :repository_routes_test_recipient, :__missing__)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearProjectClient)
    Application.put_env(:symphony_elixir, :repository_routes_projects, [])
    Application.delete_env(:symphony_elixir, :repository_routes_error)
    Application.put_env(:symphony_elixir, :repository_routes_test_recipient, self())
    RepositoryRoutes.clear_cache()

    on_exit(fn ->
      RepositoryRoutes.clear_cache()
      restore_env(:linear_client_module, previous_client)
      restore_env(:repository_routes_projects, previous_projects)
      restore_env(:repository_routes_error, previous_error)
      restore_env(:repository_routes_test_recipient, previous_recipient)
    end)

    :ok
  end

  test "dynamic discovery is disabled when allowed owners are unset" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Symphony", "https://github.com/yakisoba666rasb-star/symphony")
    ])

    settings =
      settings(%{
        "repository" => %{"allowed_owners" => [], "project_routes" => %{"octo/repo" => ["Octo"]}}
      })

    assert RepositoryRoutes.effective_project_routes(settings) == %{"octo/repo" => ["Octo"]}
    refute_receive {:team_projects_query, _external_links?, _legacy_links?}
  end

  test "discovers allowlisted project repository URL from description" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Symphony", "Repo: https://github.com/yakisoba666rasb-star/symphony")
    ])

    settings = settings()

    assert RepositoryRoutes.effective_project_routes(settings)["yakisoba666rasb-star/symphony"] == ["Symphony"]

    issue = %Issue{identifier: "LAB-1", title: "Work", project_name: "Symphony"}
    assert {:ok, "yakisoba666rasb-star/symphony"} = RepositoryResolver.project_route_slug(issue, settings)
  end

  test "discovers allowlisted project repository URL from project link" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      %{
        "id" => "project-1",
        "name" => "Worker App",
        "slugId" => "worker-app",
        "externalLinks" => %{"nodes" => [%{"url" => "https://github.com/yakisoba666rasb-star/worker-app"}]}
      }
    ])

    settings = settings()

    assert RepositoryRoutes.effective_project_routes(settings)["yakisoba666rasb-star/worker-app"] == ["Worker App"]
  end

  test "ignores project repository URL outside allowed owners" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("External", "https://github.com/not-allowed/service")
    ])

    settings = settings()

    log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    assert log =~ "owner_not_allowed"
  end

  test "rejects one project with multiple repository URLs as ambiguous" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Ambiguous", "https://github.com/yakisoba666rasb-star/one and https://github.com/yakisoba666rasb-star/two")
    ])

    settings = settings()

    log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    assert log =~ "multiple_repository_urls"
  end

  test "rejects duplicate repository claims from multiple projects" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("One", "https://github.com/yakisoba666rasb-star/symphony"),
      project("Two", "https://github.com/yakisoba666rasb-star/symphony")
    ])

    settings = settings()

    log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    assert log =~ "duplicate_repository_route"
  end

  test "does not repeat unchanged rejection warnings after refresh" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("External", "https://github.com/not-allowed/service")
    ])

    settings =
      settings(%{
        "github_intake" => %{"interval_ms" => 1}
      })

    first_log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    Process.sleep(2)

    second_log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    assert first_log =~ "owner_not_allowed"
    refute second_log =~ "owner_not_allowed"
  end

  test "missing repository URLs are debug-only and unchanged sets do not repeat" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Unregistered", nil)
    ])

    settings =
      settings(%{
        "github_intake" => %{"interval_ms" => 1}
      })

    log =
      capture_log([level: :debug], fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
        Process.sleep(2)
        assert RepositoryRoutes.effective_project_routes(settings) == %{}
      end)

    assert log =~ "[debug]"
    assert log =~ "no_repository_url"
    refute log =~ "[warning]"
    assert count_occurrences(log, "no_repository_url") == 1
  end

  test "static project routes win over dynamic discovery" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Dynamic Symphony", "https://github.com/yakisoba666rasb-star/symphony")
    ])

    settings =
      settings(%{
        "repository" => %{
          "allowed_owners" => ["yakisoba666rasb-star"],
          "project_routes" => %{"yakisoba666rasb-star/symphony" => ["Static Symphony"]}
        }
      })

    assert RepositoryRoutes.effective_project_routes(settings)["yakisoba666rasb-star/symphony"] == ["Static Symphony"]
  end

  test "caches dynamic route discovery for the intake interval" do
    Application.put_env(:symphony_elixir, :repository_routes_projects, [
      project("Symphony", "https://github.com/yakisoba666rasb-star/symphony")
    ])

    settings = settings()

    assert RepositoryRoutes.effective_project_routes(settings)["yakisoba666rasb-star/symphony"] == ["Symphony"]
    assert RepositoryRoutes.effective_project_routes(settings)["yakisoba666rasb-star/symphony"] == ["Symphony"]

    assert_receive {:team_projects_query, true, false}
    refute_receive {:team_projects_query, _external_links?, _legacy_links?}
  end

  test "negative-caches failed dynamic discovery and serves static routes" do
    Application.put_env(:symphony_elixir, :repository_routes_error, :linear_down)

    settings =
      settings(%{
        "repository" => %{
          "allowed_owners" => ["yakisoba666rasb-star"],
          "project_routes" => %{"yakisoba666rasb-star/symphony" => ["Static Symphony"]}
        }
      })

    log =
      capture_log(fn ->
        assert RepositoryRoutes.effective_project_routes(settings) == %{"yakisoba666rasb-star/symphony" => ["Static Symphony"]}
        assert RepositoryRoutes.effective_project_routes(settings) == %{"yakisoba666rasb-star/symphony" => ["Static Symphony"]}
      end)

    assert log =~ "Failed to discover Linear project repository routes"
    assert_receive {:team_projects_query, true, false}
    refute_receive {:team_projects_query, _external_links?, _legacy_links?}
  end

  defp settings(overrides \\ %{}) do
    config =
      %{
        "tracker" => %{"kind" => "linear", "team_key" => "LAB", "api_key" => "token", "all_projects" => true},
        "github_intake" => %{"enabled" => true, "interval_ms" => 60_000},
        "repository" => %{"allowed_owners" => ["yakisoba666rasb-star"]}
      }
      |> deep_merge(overrides)

    assert {:ok, settings} = Schema.parse(config)
    settings
  end

  defp project(name, description) do
    %{"id" => "project-#{name}", "name" => name, "slugId" => name, "description" => description}
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp restore_env(key, :__missing__), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp count_occurrences(text, pattern) do
    text
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
