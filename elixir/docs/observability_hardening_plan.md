# Observability and Review-Loop Hardening Plan

Status: H1/H2/H4/H5 implemented on PR #103 branch; H3 remains conditional.
H6 is implemented as an H4 runner flag.
Last updated: 2026-06-11

## Goal

Close the observability and resilience gaps found during the 2026-06-11
LAB-403 / PR #101 incident analysis, then extend the zero-touch loop
([zero_touch_loop.md](zero_touch_loop.md)) with the missing
changes-requested leg and a repeatable acceptance runner.

Incident summary: the ready-PR handoff worked correctly (reconcile found
PR #101 16s after creation, self-review approved in ~5 minutes, In Review
and Done transitions both fired), but every observation surface said
otherwise:

- `/api/v1/state` reported `running=0, blocked=0, retrying=0` while the
  async review handoff was in flight (fixed by LAB-404 / #102: the
  `reviewing` section now exposes `pending_review_handoffs`).
- `/var/log/symphony-ryo/engine.log` contained only TUI dashboard frames;
  warning-and-above runtime events are written to
  `/var/log/symphony-ryo/engine-error.log` by the shipped systemd unit, and
  all structured Logger output goes to the disk_log at
  `elixir/log/symphony.log.*`. Operators checking `journalctl` missed the
  active streams because stdout/stderr are redirected by the unit.
- Several handoff log lines carry only the issue UUID, so grepping the
  ticket key (`LAB-403`) missed them.

Implementation note: H1, H2, H4, H5, and the H6 runner scenario are now
implemented in the PR #103 branch. H3 intentionally remains a decision-gated
follow-up only if the new surfaces are insufficient.

## H1: Stall detection for pending review handoffs

Status: implemented.

Problem: LAB-401 (#99) stall detection covers `running` entries via
`last_progress_ms`, but an issue in `pending_review_handoffs` is outside
that scan. A hung reviewer session leaves the issue In Progress and the
runtime silent indefinitely; the operator cannot distinguish "review in
progress" from "review wedged".

Design:

- Each pending handoff already stores `started_at` (orchestrator.ex,
  `do_start_review_handoff_task`). Reuse it; no new state.
- Extend the per-poll stall scan (`reconcile_stalled_running_issues`) with
  a sibling pass over `state.pending_review_handoffs`:
  - `now - started_at >= stall.review_threshold_ms` (default `900_000`):
    post one Linear comment per handoff ("review handoff running for Nm,
    pr=..., will recycle at 2x threshold") and set an episode flag on the
    pending-handoff metadata (same once-per-episode pattern as
    `maybe_comment_on_stall_episode`).
  - `>= 2 * review_threshold_ms`: `Task.Supervisor.terminate_child` the
    review task, remove the pending entry, and route the issue through the
    existing terminal-error path (`review_handoff_terminal_error`) so the
    unified retry policy (#83) takes over - bounded retries, then a
    reasoned block.
- Config: extend the existing `stall` block with
  `review_threshold_ms: 900_000` (validated > polling interval). The
  existing `stall.enabled` gates both scans.
- The dashboard/API `reviewing` entries (#102) already show elapsed time,
  so the operator can see the same signal the scan acts on.

Acceptance:

- A reviewer task that never returns produces a Linear comment at 1x and
  a recycle-with-retry at 2x; logs carry `issue_id`, `issue_identifier`,
  `pr`, and elapsed ms.
- A normal review that finishes under the threshold posts nothing.

## H2: Log path repair (service mode)

Status: implemented. Repo code suppresses non-TTY dashboard rendering,
mirrors warnings/errors to stderr, improves review-handoff identifier logs,
and adds `ops/ryo/logrotate/symphony-ryo` as the operator logrotate backstop.

Problem: under systemd, stdout/stderr go to
`/var/log/symphony-ryo/engine.log` / `engine-error.log`, but Logger output
is redirected to the rotating disk_log (`LogFile`), and the only thing on
stdout is the TUI status dashboard repaint loop. Result: a 1.2 GB
`engine.log` with zero diagnostic value, an `engine-error.log` stale for
days, and `journalctl` useless during incident response.

Shipped log map:

- TUI frames and any stdout lines from `symphony-engine.service` append to
  `/var/log/symphony-ryo/engine.log` via `StandardOutput=append:...`.
- Warning-and-above runtime logs mirrored to stderr append to
  `/var/log/symphony-ryo/engine-error.log` via `StandardError=append:...`.
- Structured application logs use OTP `disk_log` wrap files at
  `<cwd>/log/symphony.log*` (`LogFile`, 10 MB x 5 files by default).
- Operator rotation for service stdout/stderr logs is
  `ops/ryo/logrotate/symphony-ryo`, covering `/var/log/symphony-ryo/*.log`.
- `journalctl -u symphony-engine.service` is useful only for deployments
  where the unit does not redirect stdout/stderr to files.

Design (three independent fixes plus one operator step):

1. **Suppress TUI rendering when stdout is not a TTY.**
   `StatusDashboard.dashboard_enabled?/0` currently only checks
   `Mix.env() != :test`. Add a TTY check (`IO.ANSI.enabled?()` reflects
   Elixir's boot-time TTY detection) so a service run renders nothing.
   `observability.dashboard_enabled` and the `enabled` override keep
   working for explicit opt-in/out.
2. **Mirror warnings and errors to stderr.** `LogFile.configure/0`
   removes the default console handler entirely. Instead, keep (or
   re-add) a `:logger_std_h` handler on `standard_error` with
   `level: :warning`, so the shipped unit's `engine-error.log` always
   captures actionable problems even when the disk_log is unavailable or
   unknown to the operator. Journald captures these warnings only when
   stdout/stderr are not redirected by the unit.
3. **Identifier coverage audit.** [logging.md](logging.md) requires
   `issue_id` and `issue_identifier` together; several review-handoff and
   Done-sync lines log only the UUID. Audit the handoff/Done-sync paths
   and add `issue_identifier` where missing so `grep LAB-NNN` finds the
   full lifecycle.
4. **Operator step (not repo code): logrotate.** Add a logrotate config
   for `/var/log/symphony-ryo/*.log` (size-based, e.g. 50 MB x 5). After
   fix 1, growth should be negligible; rotation is the backstop.

Acceptance:

- A service restart writes nothing but real log lines to `engine.log`.
- `/var/log/symphony-ryo/engine-error.log` shows warnings/errors from a
  forced failure (e.g. unreachable Linear API) under the shipped systemd
  unit.
- `grep LAB-NNN <cwd>/log/symphony.log*` returns dispatch, handoff,
  review verdict, and Done-sync lines for a completed loop.

## H3: Structured handoff trace summary (conditional)

Status: not implemented by design. Reassess after H1/H2/H4 live evidence.

Problem: diagnosing a handoff today means stitching together 5+ log lines
(PR discovery, task start, reviewer session, verdict, state update,
comment result) across reconcile and agent-down paths.

Design:

- After H1/H2 land and the next live handoff is verified, reassess. If
  diagnosis is still slow, emit one summary line when a pending handoff
  finishes (success or failure):
  `review handoff finished issue_identifier=... pr=... mode=...
  verdict=... state_update=ok|error comment=ok|error elapsed_ms=...`.
- Implementation point: `finish_pending_review_handoff/3`, which already
  sees every outcome. No new state.

Decision gate: file this only if the LAB-404 + H1 + H2 surfaces prove
insufficient during the next incident or acceptance run. Do not implement
preemptively.

## H4: Zero-touch E2E acceptance runner

Status: implemented as `mix symphony.acceptance`.

Problem: W6 (LAB-403, #101) posts per-issue loop evidence, but proving the
whole pipeline still means a human filing an issue and watching. There is
no repeatable acceptance check, so regressions surface in production runs.

Design:

- A mix task (`mix symphony.acceptance`) run manually (or via CI cron)
  against the live runtime:
  1. Files one GitHub issue in a registered repo with the W5
     `todo_labels` label (`symphony-auto`), title-tagged with a run nonce.
  2. Polls the legs with a per-leg timeout: Linear issue created (intake)
     -> Todo -> In Progress (dispatch) -> PR exists -> In Review -> human
     merge happens out-of-band -> Done -> source issue closed.
  3. Collects the W6 evidence comment and emits a single acceptance
     report (markdown to stdout/file): per-leg timestamps, latencies, and
     pass/fail per leg.
  4. `--up-to in_review` mode stops before merge so the run is fully
     unattended for CI; `--up-to done` is the explicit full-mode value, and
     omitting `--up-to` defaults to `done`. Other `--up-to` values are rejected
     before the live probe starts.
- The runner observes the runtime through GitHub + Linear APIs and does not
  mutate orchestrator state.
- Includes the H6 restart scenario as an optional flag (below).

Acceptance: one command produces a pass/fail report for a labeled issue
reaching In Review with zero human actions, with per-leg latencies.

## H5: Changes-requested rework loop

Status: implemented behind `review_rework.enabled: false` by default.

Problem: the zero-touch loop assumes In Review ends in a merge. If the
human reviewer requests changes on the PR instead, nothing happens: the
Linear issue sits In Review and the feedback waits for a manual rework
dispatch. This is the last missing leg before "merge is the only human
action" also covers rejected first drafts.

Design:

- During the poll cycle, for Linear issues in In Review with a PR
  attachment: check the PR's `reviewDecision` via
  `gh pr view --json reviewDecision,latestReviews`.
- On `CHANGES_REQUESTED`:
  - Move the issue back to In Progress (runtime owns state transitions).
  - Dispatch a rework agent into the existing workspace/branch with the
    review comments in the prompt (reuse the self-review rework prompt
    path from #83's loop).
  - On completion, the normal ready-PR handoff re-runs review and moves
    the issue back to In Review.
- Guards:
  - Once per review round: record the acted-on review submission id in
    runtime memory so one CHANGES_REQUESTED does not redispatch every poll
    during a runtime lifetime. A later persistence mechanism can strengthen
    this across restarts if live evidence shows a need.
  - Bounded by the unified retry policy: max N rework rounds (config
    `review_rework.max_rounds`, default 2), then block with a reasoned
    comment.
  - Skip merged/closed PRs; skip when a rework agent or pending handoff
    for the issue already exists.
- Config block `review_rework: {enabled: false, max_rounds: 2}` -
  explicit opt-in, default off.

Acceptance: requesting changes on a runtime-created PR produces a rework
commit addressing the comments and a return to In Review, at most
`max_rounds` times, with Linear comments documenting each round.

## H6: Restart-during-review-handoff recovery (verification)

Status: implemented as `mix symphony.acceptance --restart-during-review`.

Problem: `pending_review_handoffs` is memory-only. A runtime restart while
a review handoff is in flight kills the reviewer task. The poll-cycle
reconcile should rediscover the open PR for the In Progress issue and
restart the handoff (the same path that handled PR #101), but this has
never been verified.

Design: no new runtime code expected. Add a scenario flag to the H4
runner (`--restart-during-review`) that restarts
`symphony-engine.service` while `reviewing >= 1`, then asserts the issue
still reaches In Review within the leg timeout. If the reconcile path
does not re-arm the handoff, file the fix as a follow-up issue with the
runner output as evidence.

## Config Summary (new keys)

```yaml
stall:
  review_threshold_ms: 900000   # H1
review_rework:                  # H5
  enabled: false
  max_rounds: 2
```

All new keys default to safe/current behavior; H5 is explicit opt-in.

## Out of Scope

- Linear stale-state cleanup automation: poll reconcile + Done sync
  already recover the known stale cases; revisit only with evidence of a
  class they miss, and then as dry-run/comment-only first.
- Evidence-timeline dashboard UI: W6 evidence comments cover the need;
  reconsider after H4 reports exist as a data source.
