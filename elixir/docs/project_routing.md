# Repository and Linear Project Routing

Status: implemented (LAB-396, PR #88; LAB-408)
Last updated: 2026-06-11

## Goal

When `tracker.all_projects: true` is enabled, Symphony must route each Linear
issue to exactly one GitHub repository before dispatch. The Linear Project is
the human-visible routing label, but repository evidence from GitHub URLs and
issue text is the stronger source of truth for choosing the workspace.

The intended steady state is:

1. GitHub issue or PR evidence resolves to a repository slug such as
   `kasotuosawari-design/auto_template`.
2. Symphony finds the matching Linear Project registered on the issue's team.
3. If the issue has no project, Symphony assigns that project before dispatch.
4. Dispatch only starts after the issue's project and resolved repository agree.

## Resolution Order

Repository resolution should stay consistent across dispatch, handoff, and
project assignment paths:

1. Explicit repository configuration or override.
2. GitHub issue or PR URL attached to the Linear issue.
3. GitHub repository URL in the issue title, description, comments, or branch
   evidence.
4. A unique effective project route match from the Linear Project name or slug.
   Effective routes are `repository.project_routes` plus dynamically discovered
   Linear Project metadata routes.
5. `repository.default` only when no stronger evidence exists.

Dynamic discovery is disabled by default. Set `repository.allowed_owners` to
trusted GitHub owners, then add exactly one GitHub repository URL to a Linear
Project description or external link. Static `repository.project_routes` entries
win over dynamic routes for the same repository. A project with multiple
repository URLs, a repository claimed by multiple projects, or a repository
outside the allowlist is ignored and logged only when the rejection set changes.
Because Linear Project metadata can influence routing, only users trusted to
route agent execution should be able to edit those projects. See
[GitHub Intake Prompt-Injection Threat Model](github_intake_threat_model.md) for
the related trust assumptions.

Keep PR, issue, and cross-repository reference links out of the Project
description when dynamic discovery is enabled. A description that contains the
canonical repository URL plus GitHub URLs for other repositories is ambiguous
and is rejected as `multiple_repository_urls`; put those references in project
updates or documents instead.

Static project-route keys must use canonical GitHub slug form:

```yaml
repository:
  default: yakisoba666rasb-star/symphony
  allowed_owners:
    - yakisoba666rasb-star
  project_routes:
    yakisoba666rasb-star/symphony:
      - Symphony
    kasotuosawari-design/auto_template:
      - auto_template
```

## Missing Project Assignment

If a candidate issue has repository evidence but no Linear Project:

- Resolve the repository with the same resolver used by dispatch.
- Build project aliases from the effective route map for `repo_slug`.
- Fall back to the repository name (`owner/repo` -> `repo`) when no route is
  configured.
- Query the issue team's Linear Projects and match by normalized project name
  or slug.
- If exactly one project matches, update the Linear issue's `projectId` and
  skip dispatch for that poll. The next poll should see the project and run the
  normal dispatch guard.
- If no project matches or multiple projects match, do not dispatch. Log the
  reason and leave the issue visible for human correction.

This keeps project assignment broad: `auto_template`, `Symphony`,
`Remote-mouse_v1`, or any future registered Linear Project can be assigned when
the repository is discoverable and the team has a unique matching project.

## Invariants

- Do not dispatch a no-project issue under `all_projects: true` merely because
  the default repository exists.
- Do not discover dynamic routes unless the repository owner is explicitly
  allowlisted.
- Do not use stale or legacy Lab repositories as fallback routes.
- Do not assign a project when the repository is ambiguous.
- Do not assign a project when the matching Linear Project is not registered on
  the issue's team.
- After assigning a project, wait for the next poll instead of launching an
  agent in the same cycle.

## Operational Check

For a newly created issue with a GitHub URL and no Linear Project:

1. The first poll should add the matching Project.
2. The issue should remain otherwise unclaimed during that poll.
3. A later poll should move it from `Todo` to `In Progress` and launch the
   correct repository workspace.
4. The runtime log should show both the project assignment decision and the
   later dispatch decision with the same repository slug.
