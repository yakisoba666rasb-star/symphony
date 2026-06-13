defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    assert banner =~ "To proceed"
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "usage message includes the required guardrails acknowledgement flag" do
    assert {:error, usage} = CLI.evaluate(["--unknown"])
    assert usage =~ "Usage: symphony"
    assert usage =~ @ack_flag
  end

  test "SIGTERM trap marks runtime shutdown and exits the BEAM" do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-cli-sigterm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    ready_path = Path.join(tmp_dir, "ready")
    marker_path = Path.join(tmp_dir, "marked")
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    ebin_path = Path.expand("_build/test/lib/symphony_elixir/ebin")

    script = """
    Application.put_env(:symphony_elixir, :runtime_shutdown_observer, fn reason ->
      File.write!(
        #{inspect(marker_path)},
        "started=" <> inspect(SymphonyElixir.RuntimeShutdown.started?()) <> " reason=" <> inspect(reason)
      )
    end)

    SymphonyElixir.RuntimeShutdown.reset_for_test()
    :ok = SymphonyElixir.CLI.trap_shutdown_signal(:sigterm)
    File.write!(#{inspect(ready_path)}, "ready")
    Process.sleep(:infinity)
    """

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        args: ["--erl", "-noshell", "-pa", ebin_path, "-e", script]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      assert wait_until(fn -> File.exists?(ready_path) end, 2_000)
      assert {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      assert_receive {^port, {:exit_status, 0}}, 2_000
      assert File.read!(marker_path) == "started=true reason=:sigterm"
    after
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      File.rm_rf!(tmp_dir)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline, nil)
  end

  defp wait_until(fun, deadline, _last_result) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        result

      true ->
        Process.sleep(10)
        wait_until(fun, deadline, result)
    end
  end
end
