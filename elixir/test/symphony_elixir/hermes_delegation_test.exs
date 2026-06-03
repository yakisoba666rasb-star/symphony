defmodule SymphonyElixir.HermesDelegationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HermesDelegation
  alias SymphonyElixir.Linear.Issue

  test "assignments parses Hermes delegation lines" do
    description = """
    Work request

    ## Hermes delegation
    ASSIGN: primary=worker-a
    ASSIGN: reviewer=Hermes_PM
    """

    assert HermesDelegation.assignments(description) == %{
             "primary" => "worker-a",
             "reviewer" => "Hermes_PM"
           }
  end

  test "preferred_worker_host uses explicit worker_host before primary" do
    issue = %Issue{
      description: """
      ASSIGN: primary=worker-a
      ASSIGN: worker_host=worker-b
      """
    }

    assert HermesDelegation.preferred_worker_host(issue, ["worker-a", "worker-b"]) == "worker-b"
  end

  test "preferred_worker_host falls back to normalized primary match" do
    issue = %Issue{description: "ASSIGN: primary=Ras Codex"}

    assert HermesDelegation.preferred_worker_host(issue, ["ras-codex", "worker-b"]) == "ras-codex"
  end

  test "preferred_worker_host ignores unknown workers" do
    issue = %Issue{description: "ASSIGN: primary=Ras-Codex"}

    assert HermesDelegation.preferred_worker_host(issue, ["worker-a"]) == nil
  end

  test "preferred_worker_host logs a warning when ASSIGN value does not match any host" do
    issue = %Issue{description: "ASSIGN: primary=ghost-host"}

    assert capture_log(fn ->
             assert HermesDelegation.preferred_worker_host(issue, ["worker-a"]) == nil
           end) =~ "did not match any configured worker_hosts"
  end

  test "preferred_worker_host resolves ASSIGN primary across whitespace and case" do
    issue = %Issue{
      description: """
      ## Hermes delegation
      ASSIGN: primary=Ras Codex
      """
    }

    assert HermesDelegation.preferred_worker_host(issue, ["ras-codex", "worker-b"]) == "ras-codex"
  end
end
