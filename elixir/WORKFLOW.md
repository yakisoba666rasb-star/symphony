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
polling:
  interval_ms: 30000
workspace:
  root: ~/symphony-workspaces
repository:
  default: your-org/your-repo
  allowed:
    - your-org/your-repo
  clone_protocol: https
hooks:
  after_create: |
    repo_url="${SYMPHONY_REPOSITORY_CLONE_URL:-https://github.com/your-org/your-repo.git}"
    git clone "$repo_url" .
agent:
  max_concurrent_agents: 1
  max_turns: 20
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

Symphony owns scheduling, workspace creation, and launching Codex. Codex owns
the work inside the issue workspace: read the issue, design the change,
implement it, validate it, commit, push, and open or update a GitHub PR when the
task requires code changes.

Keep target-project code, deployment secrets, production logs, and private run
evidence outside this public engine fork. Store those artifacts in the target
repository or in operator-managed runtime storage.

## Workflow

1. Confirm the Linear issue requirements and target repository.
2. If the issue is `Todo`, move it to `In Progress` before editing.
3. Sync the workspace from the target repository's default branch.
4. Make the smallest complete change that satisfies the issue.
5. Run focused validation that matches the change.
6. Commit with the Linear key visible.
7. Push a branch and open or update a GitHub PR.
8. Include `Refs {{ issue.identifier }}` in the PR body.
9. Move the Linear issue to `In Review` only after the PR is ready for a human
   decision.
10. Leave final merge or closure to a human unless the workflow explicitly says
    otherwise.

## Completion Report

Before stopping, report:

- Linear issue identifier
- Workspace path
- Branch name
- PR URL, if created
- Validation commands and results
- Final Linear state
- Open blockers or residual risk
