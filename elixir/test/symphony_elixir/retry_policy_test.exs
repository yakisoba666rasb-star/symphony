defmodule SymphonyElixir.RetryPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryPolicy

  test "attempt cap is bounded and zero means unbounded" do
    policy = %{max_attempts: 2}

    assert RetryPolicy.allow_attempt?(1, policy)
    assert RetryPolicy.allow_attempt?(2, policy)
    refute RetryPolicy.allow_attempt?(3, policy)
    refute RetryPolicy.allow_attempt?(0, policy)
    refute RetryPolicy.allow_attempt?(1, %{})

    assert RetryPolicy.allow_attempt?(100, %{max_attempts: 0})
  end

  test "backoff uses exponential delay capped by policy" do
    policy = %{base_backoff_ms: 100, max_backoff_ms: 250, first_retry_delay_ms: nil}

    assert RetryPolicy.backoff_ms(1, policy) == 100
    assert RetryPolicy.backoff_ms(2, policy) == 200
    assert RetryPolicy.backoff_ms(3, policy) == 250
  end

  test "first continuation attempt uses configured continuation delay" do
    policy = %{base_backoff_ms: 10_000, max_backoff_ms: 300_000, first_retry_delay_ms: 1_000}

    assert RetryPolicy.backoff_ms(1, policy) == 1_000
    assert RetryPolicy.backoff_ms(2, policy) == 20_000
  end

  test "policy normalizes invalid numeric settings to safe fallbacks" do
    policy =
      RetryPolicy.policy(:unknown_context, %{
        retry: %{base_backoff_ms: 0, max_backoff_ms: 0},
        agent: %{max_retry_attempts: -1, max_retry_backoff_ms: 0}
      })

    assert policy.context == :unknown_context
    assert policy.max_attempts == 0
    assert policy.base_backoff_ms == 10_000
    assert policy.max_backoff_ms == 1
    assert policy.terminal_behavior == :block
  end

  test "new progress evidence resets retry accounting intentionally" do
    state = %{attempts: 3, evidence_fingerprint: "old"}

    reset = RetryPolicy.reset_on_progress(state, "new-pr-url")

    assert reset.attempts == 0
    assert reset.evidence_fingerprint == "new-pr-url"
    assert %DateTime{} = reset.last_progress_at

    assert RetryPolicy.reset_on_progress(reset, "new-pr-url") == reset
  end

  test "non-map retry state is reset with hashed evidence" do
    reset = RetryPolicy.reset_on_progress(:missing, %{pr: 83})

    assert reset.attempts == 0
    assert is_integer(reset.evidence_fingerprint)
    assert %DateTime{} = reset.last_progress_at
  end

  test "terminal block reason is deterministic and context-specific" do
    policy = %{context: :done_sync, max_attempts: 2}

    assert RetryPolicy.terminal_reason(policy, 3, "Linear update failed") ==
             "merged PR Done sync retry limit reached (2) after attempt 3; blocking issue: Linear update failed"
  end

  test "landing repair policy has a dedicated configurable cap" do
    policy =
      RetryPolicy.policy(:landing_repair, %{
        retry: %{max_landing_repair_attempts: 2},
        agent: %{max_retry_attempts: 5, max_retry_backoff_ms: 300_000}
      })

    assert policy.context == :landing_repair
    assert policy.max_attempts == 2
    assert RetryPolicy.allow_attempt?(2, policy)
    refute RetryPolicy.allow_attempt?(3, policy)

    assert RetryPolicy.terminal_reason(policy, 3, "still dirty") ==
             "landing repair retry limit reached (2) after attempt 3; blocking issue: still dirty"
  end

  test "terminal block reason handles nil and non-string reasons" do
    assert RetryPolicy.terminal_reason(%{context: :max_turn_continuation, max_attempts: 3}, 4, nil) ==
             "agent.max_turns continuation retry limit reached (3) after attempt 4; blocking issue"

    assert RetryPolicy.terminal_reason(%{context: :unknown_context, max_attempts: 1}, 2, :no_pr) ==
             "unknown_context retry limit reached (1) after attempt 2; blocking issue: :no_pr"
  end
end
