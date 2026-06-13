defmodule SymphonyElixir.RuntimeShutdown do
  @moduledoc false

  @key {__MODULE__, :started}

  @spec mark_started(term()) :: :ok
  def mark_started(reason \\ :shutdown) do
    :persistent_term.put(@key, {DateTime.utc_now(), reason})
    :ok
  end

  @spec started?() :: boolean()
  def started? do
    match?({_timestamp, _reason}, :persistent_term.get(@key, false))
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    :persistent_term.erase(@key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
