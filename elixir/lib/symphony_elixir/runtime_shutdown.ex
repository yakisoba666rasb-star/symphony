defmodule SymphonyElixir.RuntimeShutdown do
  @moduledoc false

  @key {__MODULE__, :started}

  @spec mark_started(term()) :: :ok
  def mark_started(reason \\ :shutdown) do
    :persistent_term.put(@key, {DateTime.utc_now(), reason})
    notify_observer(reason)
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

  defp notify_observer(reason) do
    case Application.get_env(:symphony_elixir, :runtime_shutdown_observer) do
      observer when is_function(observer, 1) -> observer.(reason)
      _ -> :ok
    end
  rescue
    _error -> :ok
  end
end
