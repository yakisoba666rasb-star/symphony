---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "your-linear-project-slug"
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
landing:
  enabled: false
  execute_enabled: false
  approval_state: Approved to Land
  in_progress_state: Landing
  blocked_state: Blocked
  interval_ms: 120000
  merge_method: squash
  max_per_run: 1
  command_timeout_ms: 120000
polling:
  interval_ms: 30000
workspace:
  root: ~/symphony-workspaces
repository:
  default: your-org/your-repo
  clone_protocol: https
hooks:
  after_create: |
    repo_url="${SYMPHONY_REPOSITORY_CLONE_URL:-https://github.com/your-org/your-repo.git}"
    git clone "$repo_url" .
agent:
  max_concurrent_agents: 1
  max_turns: 20
  max_continuations: 3
  max_retry_attempts: 5
retry:
  max_attempts: 5
  max_continuations: 3
  base_backoff_ms: 10000
  max_backoff_ms: 300000
  continuation_delay_ms: 1000
codex:
  command: codex app-server
  thread_sandbox: workspace-write
---

You are a Codex agent launched by Symphony for Linear issue
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

## Operating Contract

Symphony owns scheduling, workspace creation, runtime GitHub PR publication, and
Linear state transitions. Codex owns the work inside the issue workspace: read
the issue, design the change, implement it, validate it, and prepare local
repository changes for the runtime handoff.

Keep target-project code, deployment secrets, production logs, and private run
evidence outside this public engine fork. Store those artifacts in the target
repository or in operator-managed runtime storage.

## Workflow

1. Confirm the Linear issue requirements and target repository.
2. Do not use GitHub or Linear app connector write tools unless the runtime
   explicitly asks for them; Symphony handles PR publication and issue state
   handoff after the workspace is ready.
3. Sync the workspace from the target repository's default branch.
4. Make the smallest complete change that satisfies the issue.
5. Run focused validation that matches the change.
6. Commit with the Linear key visible.
7. Leave branch push, PR creation or update, and `In Review` transition to the
   Symphony runtime publisher.
8. Include `Refs {{ issue.identifier }}` in any local commit or PR body text you
   prepare. If the Linear issue is synced from a GitHub issue, include the
   matching GitHub closing keyword, such as `Fixes #123`, in the PR body so the
   source issue can close on merge.
9. Report whether the workspace is ready for runtime publication.
10. Leave final merge or closure to a human unless the workflow explicitly says
    otherwise.
11. If batch landing is enabled, treat `Approved to Land` as the human approval
    state for the runtime landing queue. Do not merge or close PRs directly from
    an implementation agent session; the runtime landing worker is the only
    automated path, and only when `landing.execute_enabled` is true.

## Completion Report

Before stopping, report:

- Linear issue identifier
- Workspace path
- Branch name
- PR URL, if created
- Validation commands and results
- Final Linear state
- Open blockers or residual risk
