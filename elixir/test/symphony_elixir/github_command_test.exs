defmodule SymphonyElixir.GitHubCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubCommand

  test "returns ok tuple for successful commands" do
    command = System.find_executable("sh")
    assert is_binary(command)

    assert {:ok, {"hello\n", 0}} =
             GitHubCommand.run_system_cmd(command, ["-c", "printf 'hello\\n'"], stderr_to_stdout: true)
  end

  test "preserves non-zero command status" do
    command = System.find_executable("sh")
    assert is_binary(command)

    assert {:ok, {"failed\n", 7}} =
             GitHubCommand.run_system_cmd(command, ["-c", "printf 'failed\\n'; exit 7"], stderr_to_stdout: true)
  end

  test "returns timeout instead of blocking indefinitely" do
    command = System.find_executable("sh")
    assert is_binary(command)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:command_timeout, 50}} =
             GitHubCommand.run_system_cmd(command, ["-c", "sleep 2"], timeout_ms: 50)

    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "returns command exception for missing executable" do
    assert {:error, {:command_exception, _exception_module, message}} =
             GitHubCommand.run_system_cmd("/definitely/missing/symphony-command", [], [])

    assert is_binary(message)
  end

  test "returns command exception when command runner raises" do
    assert {:error, {:command_exception, RuntimeError, "boom"}} =
             GitHubCommand.run_system_cmd("cmd", [], system_cmd: fn _cmd, _args, _opts -> raise "boom" end)
  end

  test "returns command exit when command runner exits" do
    assert {:error, {:command_exit, :boom}} =
             GitHubCommand.run_system_cmd("cmd", [], system_cmd: fn _cmd, _args, _opts -> exit(:boom) end)
  end

  test "falls back to the default timeout when timeout option is invalid" do
    command = System.find_executable("sh")
    assert is_binary(command)

    assert {:ok, {"ok", 0}} =
             GitHubCommand.run_system_cmd(command, ["-c", "printf ok"], timeout_ms: 0)
  end
end
