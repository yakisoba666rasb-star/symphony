defmodule SymphonyElixir.RetryPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryPolicy

  test "attempt cap is bounded and zero means unbounded" do
    policy = %{max_attempts: 2}

    assert RetryPolicy.allow_attempt?(1, policy)
    assert RetryPolicy.allow_attempt?(2, policy)
    refute RetryPolicy.allow_attempt?(3, policy)

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

  test "new progress evidence resets retry accounting intentionally" do
    state = %{attempts: 3, evidence_fingerprint: "old"}

    reset = RetryPolicy.reset_on_progress(state, "new-pr-url")

    assert reset.attempts == 0
    assert reset.evidence_fingerprint == "new-pr-url"
    assert %DateTime{} = reset.last_progress_at

    assert RetryPolicy.reset_on_progress(reset, "new-pr-url") == reset
  end

  test "terminal block reason is deterministic and context-specific" do
    policy = %{context: :done_sync, max_attempts: 2}

    assert RetryPolicy.terminal_reason(policy, 3, "Linear update failed") ==
             "merged PR Done sync retry limit reached (2) after attempt 3; blocking issue: Linear update failed"
  end
end
