defmodule Mix.Tasks.Symphony.Acceptance do
  use Mix.Task

  alias SymphonyElixir.AcceptanceRunner

  @shortdoc "Runs a live Symphony zero-touch acceptance probe"
  @moduledoc """
  Runs a live zero-touch acceptance probe against the configured runtime.

      mix symphony.acceptance --repo owner/name --label symphony-auto --up-to in_review

  Full mode waits through Done. `--up-to in_review` stops before human merge.
  """

  @switches [
    repo: :string,
    label: :string,
    up_to: :string,
    timeout_ms: :integer,
    poll_ms: :integer,
    output: :string,
    restart_during_review: :boolean,
    restart_command: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid symphony.acceptance option(s): #{inspect(invalid)}")
    end

    runner_opts =
      [
        repo: opts[:repo],
        label: opts[:label],
        up_to: normalize_up_to(opts[:up_to]),
        timeout_ms: opts[:timeout_ms],
        poll_ms: opts[:poll_ms],
        restart_during_review: opts[:restart_during_review] == true,
        restart_command: opts[:restart_command] || "systemctl restart symphony-engine.service"
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case AcceptanceRunner.run(runner_opts) do
      {:ok, %{report: report, status: status}} ->
        maybe_write_output(opts[:output], report)
        Mix.shell().info(report)

        if status == :passed do
          :ok
        else
          Mix.raise("symphony.acceptance failed")
        end

      {:error, reason} ->
        Mix.raise("symphony.acceptance failed: #{inspect(reason)}")
    end
  end

  defp normalize_up_to("in_review"), do: :in_review
  defp normalize_up_to(nil), do: :done
  defp normalize_up_to(_other), do: :done

  defp maybe_write_output(nil, _report), do: :ok

  defp maybe_write_output(path, report) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report <> "\n")
  end
end
