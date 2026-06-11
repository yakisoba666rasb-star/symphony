defmodule SymphonyElixir.LinearAdapterTest do
  use ExUnit.Case, async: true

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

  defmodule FakeLinearProjectFallbackClient do
    def graphql(query, %{teamKey: "LAB", first: 250}) do
      if String.contains?(query, "links(") do
        {:error, {:linear_graphql_errors, [%{"message" => "unknown field links"}]}}
      else
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
                         "description" => "https://github.com/yakisoba666rasb-star/symphony"
                       }
                     ]
                   }
                 }
               ]
             }
           }
         }}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearEvidenceClient)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
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

  test "fetches team projects and falls back when project links are not available" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearProjectFallbackClient)

    assert {:ok, [%{"name" => "Symphony", "description" => description}]} = Adapter.fetch_team_projects("LAB")
    assert description == "https://github.com/yakisoba666rasb-star/symphony"
  end
end
