defmodule Mix.Tasks.Symphony.AcceptanceTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Symphony.Acceptance

  test "defaults up_to to done when omitted" do
    opts = Acceptance.runner_opts_for_args([])

    assert opts[:up_to] == :done
  end

  test "accepts in_review up_to value" do
    opts = Acceptance.runner_opts_for_args(["--up-to", "in_review"])

    assert opts[:up_to] == :in_review
  end

  test "rejects unknown up_to values" do
    assert_raise Mix.Error, ~r/Invalid --up-to value "in-review".*done, in_review/, fn ->
      Acceptance.runner_opts_for_args(["--up-to", "in-review"])
    end
  end
end
