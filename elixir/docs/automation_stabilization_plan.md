# Symphony Automation Stabilization Plan

Status: Phase 2 implemented
Last updated: 2026-06-10

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

## Current State (verified 2026-06-10)

Already implemented (PR #62, #63, #77, #78):

| Capability | Status |
|---|---|
| GitHub issue -> Linear Backlog sync | Done |
| PR created -> In Review handoff (multi-layer guards) | Done (#62, #77) |
| Merged PR -> Linear Done sync + fallback lookup | Done (#63, #77) |
| Done sync closes source GitHub issue (`Fixes #N` + runtime close) | Done (#78) |
| Review handoff dedupe / blocked-state recovery | Done (#77) |
| Runtime env points to `yakisoba666rasb-star/symphony` | Done |
| Workspace HEAD SHA PR discovery avoids `--limit 100` list truncation | Done (#70) |
| Project route can resolve non-default repos for dispatch | Done (#86) |
| Done sync only inspects issues with PR attachment or branch evidence | Done |
| Merged issue-key matching uses token boundaries and limit 50 | Done |

Remaining gaps:

- **A. Operator-side legacy cleanup**: repository-level runtime config and
  test fixtures are cleaned up by Phase 1. Operators still need to archive
  any stale local clones and retired config directories that exist on
  individual machines.
- **B. Known stability issues in Backlog**: LAB-389 (Orchestrator god
  module), LAB-388 (coverage gate excludes core modules).
- **C. Block observability**: block comments exist, but retry limits /
  backoff are not unified and there is no detection of silent stalls.
- **D. Missing Linear Project assignment**: when an issue has GitHub repository
  evidence but no Linear Project, dispatch waits for a human to set Project.
  LAB-396 should assign a unique matching team project before dispatch. See
  [Repository and Linear Project Routing](project_routing.md).

## Implementation Plan

### Phase 1: Environment unification and legacy cleanup

Implemented in this PR.

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

In progress / next implementation target.

8. **LAB-396 / missing project auto-assignment**: when a candidate issue has
   GitHub repository evidence but no Linear Project, resolve the repository,
   find a unique matching Linear Project on the issue's team, assign it, and
   defer dispatch until the next poll. This should work for every registered
   project, not only `auto_template`.

### Phase 3: Systematic block reduction

9. **Unified retry policy** (new issue): consolidate scattered
   retry/backoff logic (stalled worker, PR lookup, handoff) into one
   policy: max N attempts, exponential backoff, and a reasoned block when
   the cap is reached.
10. **Stall detection** (new issue): detect running issues with no progress
   events for X minutes and post a status comment to Linear, so stalls are
   never silent.
11. **Block comment template** (small): every block comment includes the
   reason, attempt count, and the concrete action a human should take.

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

Phase 1 (done) -> LAB-387 -> Done sync throttling -> LAB-396 ->
Phase 3 -> LAB-389. New issues in Phases 2-3 should be filed in Linear so
Symphony itself can implement them.
