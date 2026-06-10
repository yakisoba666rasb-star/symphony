---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  team_key: LAB
  all_projects: true
  project_name: Symphony
  project_slug: symphony-afe8a6524892
  active_states:
    - Todo
    - In Progress
  review_state: In Review
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 30000
github_intake:
  enabled: true
  state: Backlog
  interval_ms: 300000
  limit: 100
workspace:
  root: /home/ryo/workspaces/symphony
repository:
  default: yakisoba666rasb-star/symphony
  clone_protocol: https
  project_routes:
    yakisoba666rasb-star/symphony:
      - Symphony
      - afe8a6524892
  validation:
    profiles:
      yakisoba666rasb-star/symphony: |
        cd elixir
        mise exec -- mix test
      ryo1111-qqq/Remote-mouse_v1: |
        if [ -f mobile/pubspec.yaml ]; then
          (cd mobile && flutter test)
        elif [ -f pubspec.yaml ]; then
          flutter test
        else
          printf '%s\n' 'No Flutter pubspec.yaml found for Remote-mouse_v1 validation.'
          exit 1
        fi
hooks:
  after_create: |
    repo_url="${SYMPHONY_REPOSITORY_CLONE_URL:-https://github.com/yakisoba666rasb-star/symphony.git}"
    git clone "$repo_url" .
  before_run: |
    git fetch origin main
    git rebase origin/main || { git rebase --abort; printf '%s\n' 'Rebase failed before Codex run; record the blocker on Linear and keep the issue in In Progress.'; exit 1; }
  after_run: |
    case "${SYMPHONY_REPOSITORY:-yakisoba666rasb-star/symphony}" in
      yakisoba666rasb-star/symphony)
        cd elixir
        mise exec -- mix test
        ;;
      ryo1111-qqq/Remote-mouse_v1)
        if [ -f mobile/pubspec.yaml ]; then
          (cd mobile && flutter test)
        elif [ -f pubspec.yaml ]; then
          flutter test
        else
          printf '%s\n' 'No Flutter pubspec.yaml found for Remote-mouse_v1 validation.'
          exit 1
        fi
        ;;
      *)
        if [ -f package.json ]; then
          if [ -f package-lock.json ]; then
            npm ci
          else
            npm install
          fi
          npm test
        elif [ -f pyproject.toml ] || [ -d tests ]; then
          python3 -m pytest
        elif [ -f pubspec.yaml ]; then
          flutter test
        else
          printf 'No validation profile or standard test entrypoint found for %s\n' "$SYMPHONY_REPOSITORY"
        fi
        ;;
    esac
  timeout_ms: 60000
agent:
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_attempts: 5
  max_retry_backoff_ms: 300000
retry:
  max_attempts: 5
  max_continuations: 3
  base_backoff_ms: 10000
  max_backoff_ms: 300000
  continuation_delay_ms: 1000
codex:
  command: codex --config 'model="gpt-5.5"' --sandbox danger-full-access app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: dangerFullAccess
  allow_linear_graphql_mutations: true
---

# Symphony Agent

You are the Codex app-server agent launched by Symphony for Linear issue
`{{ issue.identifier }}`.

Target repository: `{{ repository.slug }}`.
Repository clone URL: `{{ repository.clone_url }}`.
{% if repository.github_issue_url %}GitHub source issue: `{{ repository.github_issue_url }}`.{% endif %}

Issue context:

- Identifier: `{{ issue.identifier }}`
- Title: `{{ issue.title }}`
- Current status: `{{ issue.state }}`
- Labels: `{{ issue.labels }}`
- URL: `{{ issue.url }}`

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Symphony Boundary

Symphony is the scheduler and runner. It polls Linear, creates an isolated
workspace for each issue, launches Codex app-server, manages retries and
cancellation, and exposes runtime observability.

The Codex agent owns the work inside the issue workspace: read the issue,
design the change, implement it, validate it, commit, push, open or update the
GitHub PR, request or inspect GitHub review, fix requested changes, and update
Linear with visible evidence.

Keep normal work in this official Symphony shape. Do not add Lab-specific
sidecar orchestration, local recovery CLIs, or repository-specific review bots
to the normal path.

## Sources Of Truth

- Linear is the source of truth for task identity, status, priority, labels, and
  human-visible work queue.
- GitHub is the source of truth for branches, commits, PRs, checks, and PR
  reviews.
- Symphony runtime state and local `.symphony-ryo` artifacts are operational
  evidence only.

## Tracker Updates

Use Symphony's `linear_graphql` app-server tool for Linear reads and comments.
Issue state transitions are runtime-owned. The agent should leave visible
handoff evidence, not perform Linear state mutations directly.

If a required state transition does not happen, leave a visible blocker in the
PR or Linear issue and keep working from the current state until the runtime
or a human moves it.

## State Map

- `Backlog`: not active for Symphony dispatch.
- `Todo`: move to `In Progress`, create a workpad/plan, then implement.
- `In Progress`: continue design, implementation, validation, PR creation, and
  review work.
- `In Review`: this project's name for the official human-review handoff. The
  PR is ready for a human decision. Do not continue unless the issue moves back
  to `In Progress`.
- `Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`: terminal.

## Superpowers planning gate

Before implementation, always use `superpowers:brainstorming` to clarify requirements,
unknowns, and risks. Then use `superpowers:writing-plans` to create an implementation plan.

Record the planning artifact in a Linear comment, PR body, or workpad. Include at least:

- Requirements summary
- Acceptance criteria
- Implementation steps
- Verification method
- Open questions or blockers

Important: If no planning artifact exists, implementation is blocked. Do not edit code,
commit, push, or create a PR. Record that implementation is blocked because the planning
artifact is missing, and keep the issue in `In Progress`.

## Execution Checklist

1. Read the Linear issue, acceptance criteria, labels, blockers, and target repo.
2. Complete the Superpowers planning gate above and record the planning artifact
   before editing.
3. Confirm the current workspace branch with `git branch --show-current`.
   Preserve that branch for the whole run. Do not create, rename, or switch to
   a different implementation branch unless the workspace has no usable branch.
4. Sync from `origin/main` before editing.
5. Implement the smallest complete change that satisfies the issue.
6. Run targeted validation. Use the configured `hooks.after_run` command as the
   default smoke-safe check unless the issue requires broader validation.
7. Commit with the Linear key visible.
8. Push the current workspace branch. If you had to create a branch because none
   existed, its name must include the Linear key.
9. Open or update a GitHub PR from that same branch as the proof-of-work
    surface. Include the Linear issue URL and `Refs {{ issue.identifier }}` in
    the PR body.
10. Keep the PR draft while known blockers remain. When validation is complete
    and no known blocker remains, make the PR ready for human review when the
    available GitHub tooling supports it.
11. Request or inspect review through GitHub PR review tooling when available.
12. If review or checks request changes, fix, validate, push, and request or
    inspect review again. If Linear is not active, record that blocker instead
    of mutating state directly.
13. Leave a handoff comment with the PR URL, branch, commit, validation results,
    and open blockers. The runtime moves Linear to `In Review` after it can
    discover the ready PR.
14. Leave final merge or closure to a human unless the workflow/service policy
    explicitly allows the agent to perform it. An issue description alone is not
    enough authorization to merge or close a PR.

## Review Rules

Use GitHub as the review source of truth.

- Treat GitHub checks, PR state, formal PR reviews, and PR comments as review
  evidence.
- `CHANGES_REQUESTED` or failing required checks keep the issue active.
- Free-form comments, Linear comments, and local notes are supporting context,
  not substitutes for the current GitHub PR state.
- If review tooling, credentials, or network access are unavailable, keep the
  issue in `In Progress`, record the blocker in Linear or the PR, and stop
  safely.
- Closing an unmerged PR is not completion. Do not move Linear to `Done` unless
  the work is actually accepted or the issue explicitly asks for that terminal
  state.

## Completion Report

Before stopping, report:

- Linear issue identifier and final Linear state.
- Workspace path.
- Branch name.
- PR URL.
- Review state.
- Validation commands and results.
- Open blockers or residual risk.
- Final handoff state.
