# GitHub Intake Prompt-Injection Threat Model

Status: implemented policy
Last updated: 2026-06-12

## Scope

GitHub intake copies externally authored GitHub issues into Linear so Symphony
can eventually dispatch a coding agent. The GitHub issue title and body are
untrusted input: on public repositories, anyone who can open an issue can write
content that may later be rendered into the agent prompt.

The agent runs with the workflow's configured workspace, command, Linear, and
GitHub permissions. Treat any path that moves external issue text into an active
Linear state as a prompt-injection boundary.

## Trust Boundary

Default intake keeps external content in Backlog until a trusted actor promotes
it:

```text
External GitHub issue title/body
  (untrusted; public issue authors may write this)
        |
        v
Linear Backlog issue created by GitHub intake
  (untrusted queue; not eligible for agent dispatch)
        |
        | human Backlog -> Todo promotion
        | or github_intake.todo_labels label gate
        v
Linear Todo / first active state
  (trusted for dispatch by policy)
        |
        v
Agent prompt and workspace execution
  (code execution, git operations, tracker comments, PR publication)
```

The security decision is the promotion step, not the GitHub-to-Linear copy. A
Backlog issue can contain hostile instructions because Backlog is outside the
dispatch set. Once the issue enters Todo or another active state, Symphony may
render its title and body into the agent prompt.

## Promotion Rules

The safe default is manual review:

- GitHub intake creates Linear issues in `github_intake.state`, normally
  `Backlog`.
- Backlog is not an active dispatch state.
- A human reviews the imported issue and promotes it to Todo only when it is
  acceptable for an agent to read and act on the issue text.

`github_intake.todo_labels` is an explicit opt-in shortcut:

- A GitHub issue carrying any configured `todo_labels` value is created directly
  in the first active tracker state, normally Todo.
- This shortcut is only a security boundary if applying those labels is limited
  to trusted repository users.
- Operators MUST keep label application restricted to users with the target
  repository's write or triage permission, or an equivalent trusted automation
  path.
- Do not use labels that untrusted GitHub issue authors can add or influence.

If those permission assumptions are not true for a repository, leave
`todo_labels` empty and keep the manual Backlog review boundary.

## Dynamic Repository Routes

Dynamic repository routes let Linear Project metadata select the repository for
an issue. This is a separate trust boundary from prompt injection, but it affects
which workspace and GitHub remote an agent receives.

The dynamic route trust model is:

- `repository.allowed_owners` is the GitHub owner allowlist. Dynamic discovery is
  disabled unless the repository owner appears in this list.
- Linear Project descriptions and external links are trusted only as far as the
  people who can edit those projects are trusted to route work.
- Therefore, enabling dynamic routes means: a user who can edit Linear Project
  metadata can influence repository routing within the configured
  `repository.allowed_owners` allowlist.

Keep `repository.allowed_owners` narrow, and limit Linear Project edit
permissions to people trusted to choose repositories for agent execution.

## Required Reassessment

Any change that weakens or bypasses the promotion step MUST re-evaluate this
threat model before it ships. This includes:

- Adding automatic Backlog -> Todo promotion.
- Broadening `github_intake.todo_labels` to labels untrusted users can apply.
- Treating GitHub issue content, GitHub comments, or Linear Backlog content as
  trusted without a human or permission-gated review.
- Changing dynamic route discovery so repository routing can be influenced
  outside `repository.allowed_owners` or by untrusted Linear Project editors.

When in doubt, keep external GitHub content in Backlog and require a human
promotion decision.
