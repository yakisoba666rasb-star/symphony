# Zero-Touch GitHub Issue Loop

Status: design
Last updated: 2026-06-11

## Goal

A single GitHub issue drives the whole development loop with no human action
except the final merge decision:

```
GitHub issue filed
  -> Linear Backlog issue auto-created (intake)
  -> repository + Linear Project auto-resolved
  -> dispatch -> agent implements -> self-review / rework loop
  -> ready PR detected -> Linear In Review
  -> human merges PR
  -> Linear Done + source GitHub issue closed
```

Ownership model:

- **Symphony runtime** owns all Linear state transitions and GitHub
  publication. It is the control plane.
- **Linear** is the work queue and the human-visible audit surface.
- **GitHub** holds source issues, PRs, and merge evidence.
- Agents may only comment on Linear (`commentCreate`/`commentUpdate`);
  they never move issue states or projects.

## Loop Legs and Current Status

| # | Leg | Status |
|---|---|---|
| 1 | GitHub issue -> Linear Backlog intake | Implemented (#90), hardening in review (#94: boundary-match must-fix pending) |
| 2 | Missing Linear Project auto-assignment | Done (#88, LAB-396) |
| 3 | Project-route dispatch to non-default repos | Done (#86) |
| 4 | Implement + self-review / rework loop, bounded retries | Done (#83, LAB-391; verified end-to-end 2026-06-10) |
| 5 | Ready PR detection -> In Review handoff | Done (#84, #85, #89) |
| 6 | Merged PR -> Linear Done | Done (#63, #77, #78) |
| 7 | Done -> close source GitHub issue | Done (#78 + `Code.ensure_loaded?` fix) |

## Failure-Resilience Model

| Failure | Defense |
|---|---|
| Runtime restart / in-memory state loss | Poll-cycle reconcile rebuilds running/blocked/claimed views from Linear + GitHub. Intake dedupe is backed by Linear attachments, not memory, so restarts cannot cause duplicate imports. Fingerprint caches (below) are best-effort accelerators only; losing them costs extra queries, never correctness. |
| Linear attachment missing (create succeeded, attach failed) | Two-stage dedupe: `attachmentsForURL`, then description-URL fallback with **token-boundary matching**, which repairs the missing attachment instead of creating a duplicate (#94). |
| Wrong PR selected for handoff / Done sync | Token-boundary issue-key matching, unique-open-PR selection (attachment -> branch -> URL -> identifier), explicit ambiguity rejection (#84, #85). |
| Duplicate Linear issue creation | Same two-stage dedupe; substring prefix collisions (`issues/9` vs `issues/90`) rejected by boundary regex. |
| Silent stalls / unbounded retries | Unified retry policy (#83): bounded attempts, exponential backoff, reasoned Linear block comment. Stall detection (W4) closes the remaining gap. |

## Remaining Work

Each item below should be filed as its own Linear issue so Symphony
implements it. Recommended order: W0 -> W1 -> W3 -> W2 -> W4 -> W5 -> W6.

### W0: Land intake hardening and enable the runtime

- Merge #94 after the description-fallback boundary-match fix
  (reuse the `text_contains_token?` regex from `github_pr_lookup.ex`).
- Rebuild (`mix build`), restart `symphony-engine.service`.
- First sync imports up to `limit` open issues per configured repo into
  Backlog; review the imported set once before promoting anything to Todo.

### W1: Intake failure fingerprint cache

Problem: GitHub issues that cannot be imported (`no_project_match`,
attachment repair failures, transient Linear errors) are retried on every
intake interval, consuming GraphQL quota with the same outcome.

Design:

- Orchestrator state gains `github_intake_attempts ::
  %{url => %{reason: term(), attempts: pos_integer(), last_attempt_ms: integer()}}`.
- The map is passed into `GitHubIssue.sync_open_issues_to_linear/3` and the
  updated map is returned with the sync result (keep `GitHubIssue` stateless).
- Skip a URL while `now - last_attempt_ms < github_intake.retry_ttl_ms`
  (config, default `3_600_000`, validated >= `interval_ms`).
- Delete the entry on successful create/repair or when the URL disappears
  from the open-issue list (issue closed externally).
- Memory-only by design: a restart re-attempts once, which is harmless.

### W2: Asynchronous intake (off the poll path)

Problem: intake runs synchronously inside the orchestrator poll cycle; a
large first import blocks dispatch, reconcile, and handoff processing.

Design:

- Run the sync via
  `Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> ... end)`.
- State gains `github_intake_task :: Task.t() | nil`. While set, the
  interval gate refuses to start another sync.
- `handle_info({ref, {result, attempts}}, ...)` stores the updated attempts
  map, logs the summary, sets `last_github_intake_sync_ms`, clears the task.
- `handle_info({:DOWN, ...})` for crash: log warning, clear the task, leave
  `last_github_intake_sync_ms` set so the next attempt waits a full interval.
- If a task outlives one full interval, log a warning (visibility only; the
  single-flight gate already prevents overlap).

### W3: Done sync interval gating

Problem: merged-PR Done sync evidence checks run on every poll cycle
(~30s), generating steady GitHub/Linear API churn.

Design:

- New config block `done_sync: {interval_ms: 120_000}` (validated >=
  polling interval), state field `last_done_sync_ms`.
- Gate `sync_merged_linked_pull_requests_to_done/1` with the same
  monotonic-interval helper pattern as intake.
- Accepted tradeoff: merge -> Done latency is bounded by the interval.
  Keep the immediate post-handoff check (review flow) unaffected.

### W4: Stall detection

Problem: a running agent that stops emitting progress is invisible until an
operator reads logs. Goal: no silent stalls.

Design:

- Stamp `last_progress_ms` on the running entry at agent start and inside
  `integrate_codex_update/2` (every Codex event already flows through it).
- Each poll cycle, scan running entries:
  - `now - last_progress_ms >= stall.threshold_ms` (default `900_000`):
    post a Linear comment once per episode ("no progress for Nm,
    session=..., will recycle at 2x threshold") and set an episode flag.
  - `>= 2 * threshold`: stop the agent through the existing stop path so the
    unified retry policy (#83) takes over - bounded retries, then a
    reasoned block.
- Config block `stall: {enabled: true, threshold_ms: 900_000}`.
- Comment content follows the block-comment contract: reason, attempt
  count, concrete next action.

### W5: Label-gated zero-touch promotion

Problem: intake lands issues in Backlog, so a human still promotes each one
to Todo. That is the right safety default but blocks full zero-touch.

Design:

- New config `github_intake.todo_labels: []` (list of GitHub label names).
- Add `labels` to the `gh issue list --json` fields. When an open issue
  carries any configured label, create the Linear issue directly in the
  tracker's first active state (Todo) instead of `github_intake.state`.
- Everything downstream is unchanged: dispatch still requires a uniquely
  resolved repository and project, and concurrency stays capped by
  `agent.max_concurrent_agents`.
- Default `[]` keeps current behavior; zero-touch is an explicit opt-in
  per label (for example `symphony-auto`).

### W6: Zero-touch E2E measurement

Goal: prove and keep proving that "file one GitHub issue, only merge by
hand" works, with numbers.

Design:

- **Loop evidence comment**: when Done sync completes for an issue whose
  origin is a GitHub intake attachment, post one summary comment on the
  Linear issue with the leg timeline: `intake_at`, `dispatched_at`,
  `pr_created_at`, `in_review_at`, `merged_at`, `done_at`,
  `source_closed_at`. Derive timestamps from Linear issue history,
  attachments, and the GitHub PR/issue APIs at Done time (no new
  runtime persistence; restart-safe).
- **KPIs**:
  - zero-touch completion rate: loops finished with no human state moves
    (Linear `issueHistory` actor check) other than the merge.
  - per-leg latency from the evidence comments.
  - human unblock interventions per week (existing Phase 3 KPI).
- **Acceptance run**: file one labeled GitHub issue (W5) in a registered
  repo and verify it reaches Done + source-closed with merge as the only
  human action; record the evidence comment as the proof artifact.

## Config Summary (new keys)

```yaml
github_intake:
  retry_ttl_ms: 3600000      # W1
  todo_labels: []            # W5
done_sync:
  interval_ms: 120000        # W3
stall:
  enabled: true              # W4
  threshold_ms: 900000
```

All new keys default to safe/current behavior; every feature is opt-in or
latency-neutral by default.
