defmodule SymphonyElixir.ReviewRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewRunner

  defmodule FakeReviewLoopAppServer do
    def start_session(workspace, opts) do
      send(test_pid(), {:codex_session_opts, opts})
      {:ok, %{workspace: workspace}}
    end

    def run_turn(%{workspace: workspace}, prompt, _issue, _opts) do
      send(test_pid(), {:codex_turn, prompt})

      cond do
        String.contains?(prompt, "independent reviewer") ->
          verdict =
            case Process.get(:review_verdicts, []) do
              [next | rest] ->
                Process.put(:review_verdicts, rest)
                next

              [] ->
                %{"approved_equivalent" => true, "blocking_findings" => [], "tests_required" => [], "residual_risk" => ""}
            end

          write_verdict!(workspace, verdict)
          {:ok, %{result: :turn_completed}}

        String.contains?(prompt, "implementer in the Symphony rework loop") ->
          send(test_pid(), {:rework_turn, prompt})
          {:ok, %{result: :turn_completed}}
      end
    end

    def stop_session(_session), do: :ok

    defp write_verdict!(_workspace, :missing), do: :ok
    defp write_verdict!(workspace, {:raw, raw}), do: File.write!(Path.join(workspace, ".symphony-review-verdict.json"), raw)
    defp write_verdict!(workspace, verdict), do: File.write!(Path.join(workspace, ".symphony-review-verdict.json"), Jason.encode!(verdict))

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :test_pid)
  end

  test "returns approve-equivalent verdict without rework" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-approve-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())

      Process.put(:review_verdicts, [
        %{"approved_equivalent" => true, "blocking_findings" => [], "tests_required" => [], "residual_risk" => ""}
      ])

      assert {:ok, %{approved_equivalent: true, blocking_findings: []}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer
               )

      assert_receive {:codex_turn, prompt}
      assert prompt =~ "independent reviewer"
      refute File.exists?(Path.join(test_root, ".symphony-review-verdict.json"))
      refute_receive {:rework_turn, _prompt}, 100
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "runs rework, publishes the rework branch, then re-reviews" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-rework-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())

      Process.put(:review_verdicts, [
        %{
          "approved_equivalent" => false,
          "blocking_findings" => ["PR update is missing"],
          "tests_required" => ["mix test"],
          "residual_risk" => "stale PR"
        },
        %{"approved_equivalent" => true, "blocking_findings" => [], "tests_required" => [], "residual_risk" => ""}
      ])

      assert {:ok, %{approved_equivalent: true}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer,
                 max_review_fix_loops: 1,
                 implementer_codex_command: "codex --profile implementer app-server",
                 reviewer_codex_command: "codex --profile reviewer app-server",
                 publish_rework: fn ->
                   send(self(), :publish_rework)
                   {:ok, %{"number" => 238, "url" => "https://github.example/pull/238"}}
                 end
               )

      assert_receive {:codex_turn, first_review_prompt}
      assert first_review_prompt =~ "independent reviewer"
      assert_receive {:codex_session_opts, review_opts}
      assert review_opts[:codex_command] == "codex --profile reviewer app-server"
      assert_receive {:codex_turn, rework_codex_prompt}
      assert rework_codex_prompt =~ "implementer in the Symphony rework loop"
      assert_receive {:codex_session_opts, rework_opts}
      assert rework_opts[:codex_command] == "codex --profile implementer app-server"
      assert_receive {:rework_turn, rework_prompt}
      assert rework_prompt =~ "PR update is missing"
      assert_receive :publish_rework
      assert_receive {:codex_turn, second_review_prompt}
      assert second_review_prompt =~ "Review loop index: 1"
      refute File.exists?(Path.join(test_root, ".symphony-review-verdict.json"))
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "runs rework when reviewer writes structured blocking findings" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-structured-rework-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())

      Process.put(:review_verdicts, [
        %{
          "approved_equivalent" => false,
          "blocking_findings" => [
            %{
              "file" => "tests/test_server_ui.py",
              "line" => 766,
              "issue" => "Expected excluded history card"
            }
          ],
          "tests_required" => ["PYTHONPATH=. pytest -q tests/test_server_ui.py::ServerUiTest::test_history"],
          "residual_risk" => "CI should pass after assertion update"
        },
        %{"approved_equivalent" => true, "blocking_findings" => [], "tests_required" => [], "residual_risk" => ""}
      ])

      assert {:ok, %{approved_equivalent: true}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-277", title: "Runtime rework loop"},
                 %{"number" => 381, "url" => "https://github.example/pull/381"},
                 app_server_module: FakeReviewLoopAppServer,
                 max_review_fix_loops: 1,
                 publish_rework: fn ->
                   send(self(), :publish_rework)
                   {:ok, %{"number" => 381, "url" => "https://github.example/pull/381"}}
                 end
               )

      assert_receive {:rework_turn, rework_prompt}
      assert rework_prompt =~ "tests/test_server_ui.py:766"
      assert rework_prompt =~ "Expected excluded history card"
      assert_receive :publish_rework
      refute File.exists?(Path.join(test_root, ".symphony-review-verdict.json"))
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "stops when max review fix loops is reached" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-max-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())

      Process.put(:review_verdicts, [
        %{
          "approved_equivalent" => false,
          "blocking_findings" => ["still broken"],
          "tests_required" => [],
          "residual_risk" => ""
        }
      ])

      assert {:error, {:max_review_fix_loops_reached, 0, %{approved_equivalent: false}}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer,
                 max_review_fix_loops: 0
               )

      refute_receive {:rework_turn, _prompt}, 100
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "fails closed when reviewer does not write a verdict file" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-missing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())
      Process.put(:review_verdicts, [:missing])

      assert {:error, {:review_verdict_missing, path}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer
               )

      assert path == Path.join(test_root, ".symphony-review-verdict.json")
      refute_receive {:rework_turn, _prompt}, 100
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "fails closed when reviewer writes invalid JSON" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-invalid-json-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())
      Process.put(:review_verdicts, [{:raw, "{not-json"}])

      assert {:error, {:invalid_review_verdict_json, _message}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer
               )

      refute_receive {:rework_turn, _prompt}, 100
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  test "fails closed when reviewer verdict omits approved_equivalent" do
    test_root = Path.join(System.tmp_dir!(), "symphony-review-runner-invalid-schema-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    previous_test_pid = Application.get_env(:symphony_elixir, :test_pid)

    try do
      Application.put_env(:symphony_elixir, :test_pid, self())
      Process.put(:review_verdicts, [%{"blocking_findings" => []}])

      assert {:error, {:invalid_review_verdict, :approved_equivalent_required}} =
               ReviewRunner.run_loop(
                 test_root,
                 %Issue{identifier: "LAB-238", title: "Runtime loop"},
                 %{"number" => 238, "url" => "https://github.example/pull/238"},
                 app_server_module: FakeReviewLoopAppServer
               )

      refute_receive {:rework_turn, _prompt}, 100
    after
      restore_app_env(:test_pid, previous_test_pid)
      File.rm_rf(test_root)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
