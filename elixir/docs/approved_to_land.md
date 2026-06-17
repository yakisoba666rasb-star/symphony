# Approved to Land

Status: draft design
Last updated: 2026-06-17

## Goal

Use Linear itself as the human approval surface for batch landing. A human moves
one or more issues from `In Review` to `Approved to Land`; Symphony then plans
and executes the approved landing queue in a bounded, auditable way.

This keeps final merge authority separate from implementation agents while
removing the operator burden of choosing merge order by hand.

## Linear State Model

Recommended workflow states:

| State | Owner | Meaning |
|---|---|---|
| `In Review` | Symphony runtime | PR is ready for a human final decision. |
| `Approved to Land` | Human | Human has approved Symphony to plan landing for this issue. |
| `Landing` | Symphony runtime | Symphony is actively merging, closing, or repairing the approved queue. |
| `Blocked` | Symphony runtime | Landing stopped and needs human attention. |
| `Done` | Symphony runtime | Accepted work landed and Done sync completed. |
| `Closed` / `Duplicate` / `Cancelled` | Human or Symphony runtime | Work should not land as a merge. |

`Approved to Land` is not an implementation dispatch state. The ordinary agent
dispatch loop must continue to treat only configured `tracker.active_states`
such as `Todo` and `In Progress` as implementation candidates.

## Configuration

The draft workflow configuration is:

```yaml
landing:
  enabled: false
  approval_state: Approved to Land
  in_progress_state: Landing
  blocked_state: Blocked
  interval_ms: 120000
```

`landing.enabled` defaults to `false` so existing deployments do not start
landing work accidentally. `interval_ms` is validated against the polling
interval so landing reconcile cannot run more frequently than the main poll
cadence.

## Operator Flow

1. Symphony moves completed PR handoffs to `In Review`.
2. The operator reviews the Linear issues and GitHub PRs.
3. The operator bulk-selects approved issues in Linear and moves them to
   `Approved to Land`.
4. Symphony detects the approval state by polling or webhook.
5. Symphony writes a dry-run landing plan as a Linear comment.
6. If the plan still matches current GitHub and Linear state, Symphony moves
   planned issues to `Landing` and executes them in order.
7. Each item is revalidated immediately before action.
8. Completed merges rely on Done sync, or the landing worker explicitly moves
   the issue to `Done` after merged-PR evidence is confirmed.
9. Non-merge terminal outcomes move to `Closed`, `Duplicate`, or `Cancelled`
   only when the plan contains explicit evidence and policy permits it.

## Landing Plan

A landing plan is immutable once execution starts. It should include:

- plan id and creation timestamp
- approving Linear actor, when available
- issue identifier and issue id
- repository and PR URL
- planned action: `merge`, `close`, `duplicate`, `skip`, or `repair`
- selected order and ordering reason
- validation snapshot: PR state, draft flag, mergeability, checks, review
  decision, head SHA, base branch, linked Linear issue evidence
- blockers or assumptions

If any validation input changes between dry-run and execution, Symphony must
abort the stale plan and write a replacement dry-run comment instead of
continuing.

## Ordering Rules

The first implementation should use conservative deterministic ordering:

1. Group by repository and base branch.
2. Prefer PRs with explicit dependency relationships before dependent PRs.
3. Prefer clean, mergeable PRs before conflict repair candidates.
4. Preserve Linear priority where it is present.
5. Preserve `Approved to Land` transition time as the final tie-breaker.

If dependency or mergeability evidence is ambiguous, do not guess. Move the
issue to `Blocked` with a comment explaining the ambiguity and leave the rest of
the queue untouched or paused according to policy.

## Merge Validation

Before each merge, Symphony must verify:

- the issue is still in `Approved to Land` or `Landing`
- the issue still maps to exactly one implementation PR
- the PR is open and not draft
- the PR head SHA matches the plan or has been intentionally repaired by
  Symphony
- required checks are passing
- GitHub review state has no unresolved `CHANGES_REQUESTED`
- the base branch has not changed unexpectedly
- the PR is mergeable, or a conflict repair run has just succeeded

## Conflict Repair

Conflict repair is a separate worker mode, not merge authority for agents.

When a PR cannot merge because of conflicts:

1. Move the issue to `Landing` if it is not already there.
2. Start a Codex repair session scoped to the PR branch.
3. Ask the repair session to merge or rebase against the current base branch,
   resolve conflicts, run targeted validation, and push a repair commit.
4. Re-read GitHub checks and review state.
5. Return the issue to the landing queue only after the PR is green again.

The repair session must stop and block when resolution requires product,
security, data migration, or API-contract judgment. It must not merge the PR.

## Failure Behavior

Symphony should fail closed:

- stale plan: write a new dry-run comment and keep the issue out of `Landing`
- ambiguous PR lookup: move to `Blocked`
- failed checks or requested changes: move back to `In Review` or `Blocked`
- conflict repair cannot complete: move to `Blocked`
- GitHub or Linear write failure: retry with bounded backoff, then `Blocked`
- operator moves issue out of landing states: stop work for that issue

Every blocked outcome must include a Linear comment with the action attempted,
the evidence inspected, and the next human action needed.

## Audit Trail

Linear is the approval log. GitHub is the merge evidence source.

Each execution should leave Linear comments for:

- dry-run plan
- landing start
- per-item success or skip
- conflict repair start and result
- final queue summary

Do not treat a Linear comment alone as approval. Approval is the configured
status transition into `landing.approval_state`.
