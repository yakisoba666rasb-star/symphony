# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Runtime role

This Elixir implementation is the runtime engine. It should run against cloned
target repositories and workspaces, not become the target repository itself.

Keep project-specific code, private run evidence, deployment secrets, and
environment-specific logs outside this public engine fork. Store those in the
private target repository or in operator-managed runtime storage.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input or an unsupported approval is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Trusted
GitHub and Linear connector tool elicitations are auto-accepted by the app-server client; free-form
MCP elicitations remain blocked because a non-interactive runtime cannot answer them safely.
Blocked entries are in memory only; restarting the orchestrator clears that blocked map, so any
still-active Linear issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Related operator and design references:

- [Repository and Linear Project Routing](docs/project_routing.md): repository resolution order,
  Linear Project assignment, and dynamic route trust assumptions.
- [GitHub Intake Prompt-Injection Threat Model](docs/github_intake_threat_model.md): safety boundary
  for GitHub issue intake and label-gated promotion.
- [Zero-Touch GitHub Issue Loop](docs/zero_touch_loop.md): GitHub issue -> Linear -> PR -> Done
  lifecycle and current leg status.
- [Observability and Review-Loop Hardening Plan](docs/observability_hardening_plan.md): stall
  detection, log surfaces, acceptance runner, and changes-requested rework behavior.
- [Logging Best Practices](docs/logging.md): required log context fields and message conventions.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_continuations: 3
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Symphony does not auto-approve app-server command or file approval requests from `codex.approval_policy: never` unless `SYMPHONY_ALLOW_UNSAFE_CODEX_AUTO_APPROVE=true` is set. Trusted GitHub and Linear connector tool elicitations are handled separately.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_continuations` caps how many max-turn continuations Symphony schedules before blocking
  the issue and leaving a tracker comment. Default: `3`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- When `tracker.all_projects: true`, Symphony only dispatches issues whose repository hint matches
  their Linear project. By default the repository name must match the project name or slug. Set
  `repository.allowed_owners` to enable dynamic routes from Linear Project descriptions or links
  containing GitHub repository URLs for those owners. Use `repository.project_routes` as explicit
  overrides when names differ or a static mapping should win. Route keys must use GitHub repository
  slug form (`owner/repo`), not HTTPS or SSH URLs. See
  [Repository and Linear Project Routing](docs/project_routing.md) for the shared dispatch and
  project-assignment contract. See
  [GitHub Intake Prompt-Injection Threat Model](docs/github_intake_threat_model.md) before enabling
  GitHub intake promotion shortcuts or dynamic route editing by a broader group:

```yaml
tracker:
  kind: linear
  team_key: LAB
  all_projects: true
repository:
  default: your-org/default-repo
  allowed_owners:
    - your-org
  project_routes:
    your-org/symphony:
      - symphony
      - runtime
    your-org/worker-app:
      - Worker App
```

- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- The current recommended Codex model is declared in `SymphonyElixir.Config.current_codex_model/0`.
  When changing models, update that value first, then sweep every Markdown and workflow surface in
  the deployment tree instead of editing only one file:

```bash
new_model='gpt-5.5'
old_model='gpt-5.3-codex-spark'
rg -l "$old_model|codex-spark" README.md WORKFLOW.md docs test lib |
  xargs perl -0pi -e "s/\\Q$old_model\\E/$new_model/g; s/codex-spark/$new_model/g"
rg -n "$old_model|codex-spark" README.md WORKFLOW.md docs test lib
```

- Runtime deployments may use a copied `WORKFLOW.md` outside this repository. Check the exact
  path from the service definition, update that file too, and restart the service after it passes
  validation:

```bash
systemctl cat symphony-engine-auto-template.service
rg -n "$old_model|codex-spark" /path/from/ExecStart/WORKFLOW.md
mise exec -- mix run -e 'SymphonyElixir.Workflow.set_workflow_file_path("/path/from/ExecStart/WORKFLOW.md"); case SymphonyElixir.Config.validate!() do :ok -> IO.puts("workflow ok"); {:error, reason} -> IO.inspect(reason); System.halt(1) end'
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- The dashboard and JSON API only accept loopback requests by default. For trusted remote access,
  set `SYMPHONY_OBSERVABILITY_TOKEN` and send an `Authorization` header using the Bearer scheme.
- Binding the observability server to a non-loopback host requires
  `SYMPHONY_ALLOW_PUBLIC_OBSERVABILITY=true`. This only permits the public bind; it does not bypass
  the loopback-or-bearer-token access gate for `/` or `/api/v1/*`.
- The `linear_graphql` tool allows read-only GraphQL queries by default. Trusted mutation workflows
  must opt in with `codex.allow_linear_graphql_mutations: true` or
  `SYMPHONY_ALLOW_LINEAR_GRAPHQL_MUTATIONS=true`; even then, mutations are limited to
  `commentCreate` and `commentUpdate` so issue state changes remain runtime-owned.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

Both the dashboard and JSON API use the same access policy: local loopback clients are allowed
without a token, and non-loopback clients must provide an `Authorization` header using the Bearer
scheme with the value from `SYMPHONY_OBSERVABILITY_TOKEN`.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## Zero-touch acceptance CI

The repository also ships a GitHub Actions workflow named `zero-touch-acceptance` for probing the
live GitHub issue -> Linear -> dispatch -> PR -> In Review path. It can be started manually from
the Actions tab and also runs on the configured cron schedule.

Configure these repository secrets before expecting the workflow to run the live probe:

- `LINEAR_API_KEY`: Linear personal API key used to poll the live Symphony issues.
- `SYMPHONY_ACCEPTANCE_GITHUB_TOKEN` (optional): GitHub token used by `gh issue create`. If unset,
  the workflow uses its `GITHUB_TOKEN` with `issues: write` permission.

Configure these workflow inputs when manually dispatching, or repository variables for scheduled
runs:

- `SYMPHONY_ACCEPTANCE_REPOSITORY`: GitHub repository slug where the disposable acceptance issue is
  filed. Defaults to the current repository.
- `SYMPHONY_ACCEPTANCE_TODO_LABEL`: GitHub label that the live Symphony intake promotes to Linear.
  Defaults to `symphony-auto`.
- `SYMPHONY_ACCEPTANCE_LINEAR_TEAM_KEY`: Linear team key observed by the live Symphony runtime.
  Defaults to `LAB`.

If any required secret, input, or variable is missing, the scheduled run exits successfully with a
clear skip reason in the GitHub Step Summary instead of failing with an opaque live-test error. When
configuration is present, the workflow generates a temporary CI `WORKFLOW.md` and runs:

```bash
mix symphony.acceptance --up-to in_review
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
