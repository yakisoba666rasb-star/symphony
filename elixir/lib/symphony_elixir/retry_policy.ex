defmodule SymphonyElixir.RetryPolicy do
  @moduledoc """
  Shared retry and continuation policy decisions for runtime recovery paths.
  """

  import Bitwise, only: [<<<: 2]

  @type context ::
          :agent_failure
          | :max_turn_continuation
          | :blocked_review_handoff
          | :handoff_pr_discovery
          | :review_handoff
          | :landing_repair
          | :done_sync

  @type policy :: %{
          context: context(),
          max_attempts: non_neg_integer(),
          base_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          first_retry_delay_ms: pos_integer() | nil,
          terminal_behavior: :block
        }

  @default_base_backoff_ms 10_000
  @default_continuation_delay_ms 1_000

  @spec policy(context(), map()) :: policy()
  def policy(context, settings) when is_atom(context) do
    retry = Map.get(settings, :retry)
    agent = Map.get(settings, :agent, %{})

    %{
      context: normalize_context(context),
      max_attempts: max_attempts(context, retry, agent),
      base_backoff_ms: positive_int(Map.get(retry || %{}, :base_backoff_ms), @default_base_backoff_ms),
      max_backoff_ms: positive_int(Map.get(retry || %{}, :max_backoff_ms), Map.get(agent, :max_retry_backoff_ms, 300_000)),
      first_retry_delay_ms: first_retry_delay_ms(context, retry),
      terminal_behavior: :block
    }
  end

  @spec allow_attempt?(non_neg_integer(), policy()) :: boolean()
  def allow_attempt?(attempt, %{max_attempts: max_attempts})
      when is_integer(attempt) and attempt > 0 and is_integer(max_attempts) do
    max_attempts == 0 or attempt <= max_attempts
  end

  def allow_attempt?(_attempt, _policy), do: false

  @spec backoff_ms(pos_integer(), policy()) :: pos_integer()
  def backoff_ms(attempt, %{first_retry_delay_ms: first_delay} = policy)
      when is_integer(attempt) and attempt > 0 do
    if attempt == 1 and is_integer(first_delay) and first_delay > 0 do
      first_delay
    else
      base = positive_int(Map.get(policy, :base_backoff_ms), @default_base_backoff_ms)
      cap = positive_int(Map.get(policy, :max_backoff_ms), base)
      max_delay_power = min(attempt - 1, 10)
      min(base * (1 <<< max_delay_power), cap)
    end
  end

  @spec terminal_reason(policy(), pos_integer(), String.t() | nil) :: String.t()
  def terminal_reason(%{context: context, max_attempts: max_attempts}, attempt, reason) do
    [
      "#{context_label(context)} retry limit reached (#{max_attempts}) after attempt #{attempt}; blocking issue",
      reason_suffix(reason)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  @spec reset_on_progress(map(), term()) :: map()
  def reset_on_progress(state, evidence) when is_map(state) do
    fingerprint = evidence_fingerprint(evidence)

    if Map.get(state, :evidence_fingerprint) == fingerprint do
      state
    else
      %{
        attempts: 0,
        evidence_fingerprint: fingerprint,
        last_progress_at: DateTime.utc_now()
      }
    end
  end

  def reset_on_progress(_state, evidence) do
    reset_on_progress(%{}, evidence)
  end

  defp normalize_context(context)
       when context in [
              :agent_failure,
              :max_turn_continuation,
              :blocked_review_handoff,
              :handoff_pr_discovery,
              :review_handoff,
              :landing_repair,
              :done_sync
            ],
       do: context

  defp normalize_context(context), do: context

  defp max_attempts(:max_turn_continuation, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_continuations), Map.get(agent, :max_continuations, 3))
  end

  defp max_attempts(:review_handoff, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_review_handoff_attempts), Map.get(agent, :max_review_fix_loops, 3))
  end

  defp max_attempts(:blocked_review_handoff, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_blocked_review_handoff_attempts), Map.get(agent, :max_retry_attempts, 5))
  end

  defp max_attempts(:handoff_pr_discovery, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_handoff_pr_discovery_attempts), Map.get(agent, :max_retry_attempts, 5))
  end

  defp max_attempts(:done_sync, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_done_sync_attempts), Map.get(agent, :max_retry_attempts, 5))
  end

  defp max_attempts(:landing_repair, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_landing_repair_attempts), Map.get(agent, :max_retry_attempts, 5))
  end

  defp max_attempts(_context, retry, agent) do
    non_neg_int(Map.get(retry || %{}, :max_attempts), Map.get(agent, :max_retry_attempts, 5))
  end

  defp first_retry_delay_ms(:max_turn_continuation, retry) do
    positive_int(Map.get(retry || %{}, :continuation_delay_ms), @default_continuation_delay_ms)
  end

  defp first_retry_delay_ms(_context, _retry), do: nil

  defp non_neg_int(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, fallback) when is_integer(fallback) and fallback >= 0, do: fallback
  defp non_neg_int(_value, _fallback), do: 0

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, fallback) when is_integer(fallback) and fallback > 0, do: fallback
  defp positive_int(_value, _fallback), do: 1

  defp context_label(:agent_failure), do: "agent failure"
  defp context_label(:max_turn_continuation), do: "agent.max_turns continuation"
  defp context_label(:blocked_review_handoff), do: "blocked review handoff"
  defp context_label(:handoff_pr_discovery), do: "handoff PR discovery"
  defp context_label(:review_handoff), do: "review handoff"
  defp context_label(:landing_repair), do: "landing repair"
  defp context_label(:done_sync), do: "merged PR Done sync"
  defp context_label(context), do: to_string(context)

  defp reason_suffix(reason) when is_binary(reason) and reason != "", do: reason
  defp reason_suffix(nil), do: nil
  defp reason_suffix(reason), do: inspect(reason)

  defp evidence_fingerprint(evidence) when is_binary(evidence), do: evidence
  defp evidence_fingerprint(evidence), do: :erlang.phash2(evidence)
end
