defmodule SymphonyElixir.GitHubCommand do
  @moduledoc false

  @default_timeout_ms 30_000

  @type result :: {:ok, {String.t(), integer()}} | {:error, term()}

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec run_system_cmd(String.t(), [String.t()], keyword()) :: result()
  def run_system_cmd(cmd, args, opts) do
    {timeout_ms, cmd_opts} = Keyword.pop(opts, :timeout_ms, @default_timeout_ms)
    {system_cmd, cmd_opts} = Keyword.pop(cmd_opts, :system_cmd, &System.cmd/3)

    run_system_cmd_with_timeout(cmd, args, cmd_opts, normalize_timeout_ms(timeout_ms), system_cmd)
  end

  defp run_system_cmd_with_timeout(cmd, args, opts, timeout_ms, system_cmd) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {ref, do_run_system_cmd(cmd, args, opts, system_cmd)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:command_crashed, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, {:command_timeout, timeout_ms}}
    end
  end

  defp do_run_system_cmd(cmd, args, opts, system_cmd) do
    {:ok, system_cmd.(cmd, args, opts)}
  rescue
    exception -> {:error, {:command_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:command_exit, reason}}
  end

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_timeout_ms(_timeout_ms), do: @default_timeout_ms
end
