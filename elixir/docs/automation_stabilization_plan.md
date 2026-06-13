# Symphony Automation Stabilization Plan

Status: Phases 1-3 implemented; zero-touch loop W0-W6 implemented
(see [zero_touch_loop.md](zero_touch_loop.md)); next:
[observability_hardening_plan.md](observability_hardening_plan.md)
Last updated: 2026-06-11

## Goal

Symphony picks up a Linear issue, implements it, runs self-review / fix /
re-review loops, and reliably reaches the In Review state for a human.
Humans only do final review and merge judgment. After merge, GitHub issue,
PR, and Linear issue states converge automatically with no manual cleanup.

Required invariants:

- A GitHub issue creates a visible Linear Backlog issue.
- A created PR moves the Linear issue to In Review.
- A merged PR moves the Linear issue to Done and closes the source GitHub
  issue. No half-synced states (one side open, the other Done).
- The runtime depends only on `yakisoba666rasb-star/symphony` (Pi side).
  No legacy Lab or Mac-side configuration is used for dispatch.
- Blocks are reduced: recoverable conditions auto-recover, retries are
  bounded, and every terminal block leaves an actionable reason on Linear.

## Current State (verified 2026-06-11)

Already implemented:

| Capability | Status |
|---|---|
| PR created -> In Review handoff (multi-layer guards) | Done (#62, #77, #84, #85, #89) |
| Merged PR -> Linear Done sync + fallback lookup | Done (#63, #77) |
| Done sync closes source GitHub issue (`Fixes #N` + runtime close) | Done (#78) |
| Review handoff dedupe / blocked-state recovery | Done (#77) |
| Runtime env points to `yakisoba666rasb-star/symphony` | Done |
| Workspace HEAD SHA PR discovery avoids `--limit 100` list truncation | Done (#70) |
| Project route can resolve non-default repos for dispatch | Done (#86) |
| Done sync only inspects issues with PR attachment or branch evidence | Done |
| Merged issue-key matching uses token boundaries and limit 50 | Done |
| Unified retry policy with bounded attempts and Linear-visible reasons (LAB-391) | Done (#83) |
| Auto-assign Linear Project from repository evidence (LAB-396) | Done (#88) |
| Full loop verified end-to-end: dispatch -> implement -> self-review -> rework -> approve -> merge -> Done | Verified 2026-06-10 (LAB-391) |
| GitHub issue -> Linear Backlog intake sync (two-stage dedupe, boundary matching) | Done (#90, #94); engine rebuilt/restarted from `origin/main` on 2026-06-11 |

The zero-touch loop hardening (W1-W6: intake failure fingerprint cache,
async intake, Done sync interval gating, stall detection, label-gated
promotion, E2E evidence) is implemented; see
[Zero-Touch GitHub Issue Loop](zero_touch_loop.md) for the issue/PR map.
The observability/review-loop hardening work is tracked in
[Observability and Review-Loop Hardening](observability_hardening_plan.md):
H1/H2/H4/H5/H6 are implemented on `main`, and H3 remains conditional. Known maintainability
issues remain in Backlog: LAB-389 (Orchestrator god module), LAB-388
(coverage gate excludes core modules).

## Implementation Plan

### Phase 1: Environment unification and legacy cleanup

Implemented. Operator-side cleanup is also complete: stale local clones
(`~/symphony`, `Symphony-Ryo-Lab`) and the retired reconcile timer have been
removed; only `symphony-engine.service` runs on the Pi.

1. Document `/home/ryo/src/symphony` as the single runtime checkout.
2. Remove legacy Lab repository routes from the Pi runtime workflow.
3. Replace legacy Lab references in tests and documentation with the current
   repo or neutral fixture repositories.
4. Leave local clone deletion as an operator step, because it is machine state
   rather than repository state.

Outcome: removes the root cause of wrong-repo attachments and clones.

### Phase 2: Hardening the sync paths

Implemented.

4. **LAB-387 / GitHub issue #70**: workspace HEAD SHA handoff lookup now
   calls GitHub's commit-to-PRs API directly instead of doing
   `gh pr list --state open --limit 100` followed by the unreachable
   `--state all --limit 100` pass.
5. **Done sync throttling**: `issue_has_done_sync_evidence?` only enters
   merged-PR lookup when the Linear issue has a GitHub PR attachment or a
   branch name. Identifier-only or issue-URL-only rows are skipped.
6. **Word-boundary issue-key matching + limit raise**: merged issue PR
   lookup uses token-boundary matching, so `LAB-1` does not match
   `LAB-10`, and merged search uses `--limit 50`.
7. **Project-route dispatch**: `repository.project_routes` participates in
   repository resolution, so non-default repository issues can dispatch when
   their Linear Project uniquely maps to the repository.

### Phase 2.5: Project metadata convergence

Implemented (#88).

8. **LAB-396 / missing project auto-assignment**: when a candidate issue has
   GitHub repository evidence but no Linear Project, resolve the repository,
   find a unique matching Linear Project on the issue's team, assign it, and
   defer dispatch until the next poll. Works for every registered project.
   See [Repository and Linear Project Routing](project_routing.md).

### Phase 3: Systematic block reduction

9. **Unified retry policy (LAB-391)**: implemented (#83). Scattered
   retry/backoff logic is consolidated: bounded attempts, exponential
   backoff, and a reasoned Linear block comment when the cap is reached.
10. **Stall detection** (new issue): detect running issues with no progress
   events for X minutes and post a status comment to Linear, so stalls are
   never silent.
11. **Done sync throttling** (new issue): gate merged-PR Done sync evidence
   checks behind an interval instead of running them every poll cycle.

### Phase 4: Maintainability (after automation stabilizes)

12. **LAB-389**: decompose the Orchestrator. Start only after Phases 2-3
    land; refactoring while sync logic is churning invites conflicts.
13. **LAB-388**: include core modules in the coverage gate, paired with
    the decomposition.

## Review Operations

- Keep the existing implementer/reviewer/rework loop with
  approve-equivalent verdicts and Linear evidence comments.
- Human touch points are fixed at exactly two: final review at In Review,
  and the merge decision. Frequent human intervention anywhere else (for
  example unblocking) signals that Phase 3 is incomplete.
- KPI: human unblock interventions per week. Phase 3 is done when this
  approaches zero.

## Recommended Order

Phase 1 (done) -> Phase 2 (done) -> LAB-396 (done) -> LAB-391 retry policy
(done) -> GitHub intake (done: #90, #94) -> zero-touch loop W1-W6 (done:
#96-#101; see [zero_touch_loop.md](zero_touch_loop.md)) -> observability
hardening H1-H6 (see
[observability_hardening_plan.md](observability_hardening_plan.md)) ->
LAB-389. New issues should be filed in Linear so Symphony itself can
implement them.
