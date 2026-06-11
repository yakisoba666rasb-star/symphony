defmodule SymphonyElixir.LinearAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Adapter

  defmodule FakeLinearEvidenceClient do
    def graphql(_query, %{issueId: "issue-1", first: 100}) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "issue-1",
             "attachments" => %{"nodes" => [%{"url" => "https://github.com/octo/repo/issues/67"}]},
             "history" => %{"nodes" => [%{"toState" => %{"name" => "Done"}}]},
             "comments" => %{"nodes" => [%{"body" => "hello"}]}
           }
         }
       }}
    end

    def graphql(_query, %{issueId: "missing", first: 100}) do
      {:ok, %{"data" => %{"issue" => nil}}}
    end

    def graphql(_query, %{issueId: "error", first: 100}) do
      {:error, :linear_down}
    end
  end

  defmodule FakeLinearProjectClient do
    def graphql(query, %{teamKey: "LAB", first: 250}) do
      send_recipient({:team_projects_query, String.contains?(query, "externalLinks("), String.contains?(query, "links(")})

      {:ok,
       %{
         "data" => %{
           "teams" => %{
             "nodes" => [
               %{
                 "projects" => %{
                   "nodes" => [
                     %{
                       "id" => "project-1",
                       "name" => "Symphony",
                       "slugId" => "symphony",
                       "description" => "https://github.com/yakisoba666rasb-star/symphony",
                       "externalLinks" => %{
                         "nodes" => [%{"url" => "https://github.com/yakisoba666rasb-star/worker-app"}]
                       }
                     }
                   ]
                 }
               }
             ]
           }
         }
       }}
    end

    defp send_recipient(message) do
      case Application.get_env(:symphony_elixir, :linear_adapter_test_recipient) do
        recipient when is_pid(recipient) -> send(recipient, message)
        _ -> :ok
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_recipient = Application.get_env(:symphony_elixir, :linear_adapter_test_recipient)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearEvidenceClient)
    Application.put_env(:symphony_elixir, :linear_adapter_test_recipient, self())

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
      end

      if is_nil(previous_recipient) do
        Application.delete_env(:symphony_elixir, :linear_adapter_test_recipient)
      else
        Application.put_env(:symphony_elixir, :linear_adapter_test_recipient, previous_recipient)
      end
    end)
  end

  test "fetches zero-touch evidence details from Linear" do
    assert {:ok,
            %{
              issue: %{"id" => "issue-1"},
              attachments: [%{"url" => "https://github.com/octo/repo/issues/67"}],
              history: [%{"toState" => %{"name" => "Done"}}],
              comments: [%{"body" => "hello"}]
            }} = Adapter.fetch_zero_touch_evidence("issue-1")
  end

  test "returns an error when zero-touch evidence issue is missing" do
    assert {:error, :zero_touch_evidence_issue_not_found} = Adapter.fetch_zero_touch_evidence("missing")
  end

  test "passes through zero-touch evidence GraphQL errors" do
    assert {:error, :linear_down} = Adapter.fetch_zero_touch_evidence("error")
  end

  test "fetches team projects with current external link connection" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearProjectClient)

    assert {:ok, [%{"name" => "Symphony", "description" => description, "externalLinks" => external_links}]} =
             Adapter.fetch_team_projects("LAB")

    assert description == "https://github.com/yakisoba666rasb-star/symphony"
    assert get_in(external_links, ["nodes", Access.at(0), "url"]) == "https://github.com/yakisoba666rasb-star/worker-app"
    assert_receive {:team_projects_query, true, false}
  end
end
