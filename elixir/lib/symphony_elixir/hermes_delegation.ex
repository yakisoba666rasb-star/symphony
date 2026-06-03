defmodule SymphonyElixir.HermesDelegation do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Linear.Issue

  @assignment_line ~r/^\s*ASSIGN:\s*([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*$/i

  @spec assignments(String.t() | nil) :: map()
  def assignments(description) when is_binary(description) do
    description
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(@assignment_line, line) do
        [_line, key, value] ->
          Map.put(acc, normalize_key(key), String.trim(value))

        _ ->
          acc
      end
    end)
  end

  def assignments(_description), do: %{}

  @spec preferred_worker_host(Issue.t(), [String.t()]) :: String.t() | nil
  def preferred_worker_host(%Issue{description: description}, worker_hosts) when is_list(worker_hosts) do
    parsed = assignments(description)

    values = [parsed["worker_host"], parsed["primary"]]

    case Enum.find_value(values, &matching_worker_host(&1, worker_hosts)) do
      nil ->
        requested = Enum.reject(values, &is_nil/1)

        if requested != [] do
          Logger.warning("HermesDelegation: ASSIGN host(s) #{inspect(requested)} did not match any configured worker_hosts #{inspect(worker_hosts)}; falling back to least-loaded")
        end

        nil

      host ->
        host
    end
  end

  def preferred_worker_host(_issue, _worker_hosts), do: nil

  defp matching_worker_host(value, worker_hosts) when is_binary(value) do
    normalized_value = normalize_match_value(value)

    # Exact match preferred; normalized match (collapses separators) is a deliberate
    # forgiving fallback so "Ras Codex" matches "ras-codex" in config.
    Enum.find(worker_hosts, fn host ->
      host == value or normalize_match_value(host) == normalized_value
    end)
  end

  defp matching_worker_host(_value, _worker_hosts), do: nil

  defp normalize_key(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_match_value(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
