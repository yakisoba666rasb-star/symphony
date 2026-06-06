# Security Best Practices Report

Generated: 2026-06-06

## Remediation Update

Implemented on 2026-06-06:

- `linear_graphql` now rejects GraphQL mutations by default; trusted mutation workflows must opt in with `SYMPHONY_ALLOW_LINEAR_GRAPHQL_MUTATIONS=true`.
- Symphony no longer auto-approves app-server approval requests from `codex.approval_policy: never` unless `SYMPHONY_ALLOW_UNSAFE_CODEX_AUTO_APPROVE=true` is set.
- Observability JSON API routes now require loopback access or a bearer token via `SYMPHONY_OBSERVABILITY_TOKEN`.
- Public observability binds now require `SYMPHONY_ALLOW_PUBLIC_OBSERVABILITY=true`.
- SSH worker destinations are validated and passed after `--` to avoid option-like destination confusion.
- Hook failure logs now redact common secret/token patterns, including cleanup reason logs.

## Executive Summary

`codex-security@openai-curated` was requested, but that plugin/tool was not available in this Codex session and was not present in the install candidates. I performed a local repository security review instead, using the available `security-best-practices` workflow plus targeted code inspection and simple secret-pattern scanning.

The repository is primarily an Elixir/Phoenix prototype runtime. The available skill references do not include Elixir/Phoenix-specific guidance, so findings are based on general web/API, secrets, command execution, sandboxing, and least-privilege best practices.

No committed production secret was found by the simple pattern scan. No confirmed critical vulnerability was found in default local-only operation. The main risks are high-trust runtime features that become dangerous if exposed to untrusted Linear issue content, broad Linear tokens, public network binding, or permissive Codex policies.

Tooling limitation: framework/security scanners such as `sobelow`, `semgrep`, `gitleaks`, and `trivy` were not installed in this environment, so dependency advisories and framework-specific static analysis were not executed.

## High Severity

### H-1: Raw Linear GraphQL dynamic tool gives agent broad API power

Impact: A prompt-injected or compromised agent can issue arbitrary Linear GraphQL queries or mutations with Symphony's configured Linear token, potentially reading or changing data beyond the intended issue workflow.

Evidence:
- `elixir/lib/symphony_elixir/codex/app_server.ex:281` sends `DynamicTool.tool_specs()` to every Codex thread.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:8` defines the `linear_graphql` tool.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:56` to `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:65` executes arbitrary supplied GraphQL.
- `elixir/lib/symphony_elixir/linear/client.ex:383` to `elixir/lib/symphony_elixir/linear/client.ex:394` attaches the configured `Authorization` token.

Recommendation:
- Restrict the dynamic tool to explicit operations required by the workflow, such as issue comment creation or state transition helpers.
- If raw GraphQL is still needed, require an allowlist of operation names and block mutations by default.
- Use a least-privileged Linear token dedicated to Symphony, ideally scoped to the target workspace/project where possible.
- Log operation names, not full query variables or response payloads.

### H-2: `codex.approval_policy: "never"` auto-approves command and file-change approvals

Impact: If a workflow sets `approval_policy` to `"never"`, Symphony automatically approves Codex command execution, patch/file changes, and some user-input approval prompts for the whole session.

Evidence:
- `elixir/lib/symphony_elixir/codex/app_server.ex:54` to `elixir/lib/symphony_elixir/codex/app_server.ex:56` sets `auto_approve_requests` when `approval_policy == "never"`.
- `elixir/lib/symphony_elixir/codex/app_server.ex:527` to `elixir/lib/symphony_elixir/codex/app_server.ex:648` wires multiple approval request methods into `approve_or_require`.
- `elixir/lib/symphony_elixir/codex/app_server.ex:723` to `elixir/lib/symphony_elixir/codex/app_server.ex:743` returns approval automatically when auto-approval is enabled.
- `elixir/README.md:135` documents `"never"` as a supported value.

Recommendation:
- Treat `"never"` as an explicit unsafe mode that is refused unless a separate environment variable or CLI flag is set.
- Prefer the existing default reject policy from `elixir/lib/symphony_elixir/config/schema.ex:292` to `elixir/lib/symphony_elixir/config/schema.ex:300`.
- Add validation that disallows `danger-full-access` and `approval_policy: "never"` in normal workflows.

## Medium Severity

### M-1: Optional observability API has no authentication or authorization

Risk: When the optional HTTP server is enabled and bound beyond loopback, anyone who can reach it can read operational state and trigger refreshes.

Evidence:
- `elixir/lib/symphony_elixir_web/router.ex:30` to `elixir/lib/symphony_elixir_web/router.ex:39` exposes `/api/v1/state`, `/api/v1/refresh`, and issue-specific JSON routes without an auth plug.
- `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:11` to `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:38` returns state and accepts refresh without authentication.
- `elixir/lib/symphony_elixir_web/presenter.ex:102` to `elixir/lib/symphony_elixir_web/presenter.ex:148` includes issue IDs, worker hosts, workspace paths, sessions, errors, and last messages.
- `elixir/lib/symphony_elixir/config/schema.ex:381` to `elixir/lib/symphony_elixir/config/schema.ex:383` allows configurable `server.host`.
- `elixir/README.md:169` to `elixir/README.md:170` documents the API routes.

Recommendation:
- Keep the default loopback binding, and reject `0.0.0.0`/`::` unless an explicit unsafe flag is set.
- Add a bearer token or local-only check for JSON API routes.
- Consider removing workspace paths and raw errors from default API responses.

### M-2: Cross-origin checks are disabled for the Phoenix endpoint

Risk: If the dashboard is reachable from a browser on a non-loopback interface, `check_origin: false` weakens Phoenix's WebSocket/LiveView origin protections.

Evidence:
- `elixir/config/config.exs:13` to `elixir/config/config.exs:16` sets LiveView salt, static secret base, `check_origin: false`, and disabled server default.
- `elixir/lib/symphony_elixir_web/endpoint.ex:14` to `elixir/lib/symphony_elixir_web/endpoint.ex:17` exposes the LiveView socket.

Recommendation:
- Keep `check_origin` enabled for non-local bindings.
- Generate an allowed origin from the configured host/port when the server is started.
- Continue using runtime-generated `secret_key_base` from `elixir/lib/symphony_elixir/http_server.ex:85` to `elixir/lib/symphony_elixir/http_server.ex:87`.

### M-3: SSH worker host strings are not validated against option-like destinations

Risk: Configured `worker.ssh_hosts` values are passed to `ssh` as arguments. Because no `--` separator or destination validation is applied, a malicious or mistaken config value beginning with `-` could be interpreted as an SSH option.

Evidence:
- `elixir/lib/symphony_elixir/config/schema.ex:160` to `elixir/lib/symphony_elixir/config/schema.ex:169` casts `ssh_hosts` but does not validate syntax.
- `elixir/lib/symphony_elixir/ssh.ex:41` to `elixir/lib/symphony_elixir/ssh.ex:49` appends `destination` directly to the SSH argument list.
- `elixir/lib/symphony_elixir/ssh.ex:67` to `elixir/lib/symphony_elixir/ssh.ex:83` trims and parses `host:port` but does not reject `-`-prefixed values.

Recommendation:
- Reject empty, newline-containing, and `-`-prefixed SSH destinations.
- Insert `--` before the destination where supported by the SSH client.
- Consider accepting only `user@host`, `host`, `[ipv6]`, and `host:port` forms.

### M-4: Hook execution is intentionally powerful but not isolated from secrets

Risk: `WORKFLOW.md` hooks are shell commands and can print sensitive environment values or manipulate workspaces. Failures are logged, which can preserve leaked output.

Evidence:
- `elixir/lib/symphony_elixir/workspace.ex:443` to `elixir/lib/symphony_elixir/workspace.ex:455` runs local hooks with `System.cmd("sh", ["-lc", command])`.
- `elixir/lib/symphony_elixir/workspace.ex:501` to `elixir/lib/symphony_elixir/workspace.ex:506` logs failed hook output after truncation.
- `elixir/lib/symphony_elixir/workspace.ex:509` to `elixir/lib/symphony_elixir/workspace.ex:519` truncates output but does not redact common secret patterns.
- `elixir/WORKFLOW.md:25` to `elixir/WORKFLOW.md:28` shows `after_create` using a shell hook.

Recommendation:
- Add redaction for common token patterns before logging hook output.
- Document that hooks run as trusted operator code with access to the runtime environment.
- Consider passing a minimal environment to hooks rather than inheriting the full process environment.

## Low Severity / Hardening

### L-1: Static config contains a deterministic Phoenix secret for the disabled default endpoint

Evidence:
- `elixir/config/config.exs:13` to `elixir/config/config.exs:16` sets `secret_key_base` to repeated `"s"` and `server: false`.
- `elixir/lib/symphony_elixir/http_server.ex:34` replaces `secret_key_base` with random bytes when starting the HTTP server.

Assessment:
- This is low risk because the server default is disabled and runtime start replaces the value. Still, keeping a deterministic secret in config is easy to misuse in future code paths.

Recommendation:
- Use an explicit placeholder such as `"runtime-generated"` and ensure startup refuses to serve if the runtime secret has not been injected.

### L-2: Simple secret scan found only examples/test values

Evidence:
- `elixir/WORKFLOW.md:4` uses `$LINEAR_API_KEY`, not a committed token.
- `elixir/README.md:199` shows `export LINEAR_API_KEY=...`.
- Test files contain dummy strings such as `"resolved-secret"` and `"test-linear-api-key"`.

Recommendation:
- Add a real secret scanner such as Gitleaks to CI.
- Add dependency and framework scanners such as Sobelow and `mix hex.audit` or equivalent once Mix tooling is available.

## Positive Findings

- Default Codex turn sandbox is workspace-scoped with network disabled in `elixir/lib/symphony_elixir/config/schema.ex:624` to `elixir/lib/symphony_elixir/config/schema.ex:632`.
- Local workspace path validation canonicalizes symlinks and rejects escapes in `elixir/lib/symphony_elixir/workspace.ex:521` to `elixir/lib/symphony_elixir/workspace.ex:547`.
- App-server cwd validation similarly rejects workspace root and symlink escapes in `elixir/lib/symphony_elixir/codex/app_server.ex:148` to `elixir/lib/symphony_elixir/codex/app_server.ex:174`.
- Repository resolution validates GitHub slug shape and supports an allowlist in `elixir/lib/symphony_elixir/repository_resolver.ex:138` to `elixir/lib/symphony_elixir/repository_resolver.ex:169`.
- Review workflow settings intentionally reject unsafe auto-merge policy changes in `elixir/lib/symphony_elixir/config/schema.ex:264` to `elixir/lib/symphony_elixir/config/schema.ex:269`.

## Recommended Fix Order

1. Put guardrails around `linear_graphql`: operation allowlist or dedicated narrow helper tools.
2. Add config validation or an explicit unsafe flag for `approval_policy: "never"` and `danger-full-access`.
3. Protect the observability API with local-only enforcement or bearer auth, and keep `check_origin` enabled when not loopback.
4. Validate SSH worker destinations and add `--` before destination arguments where compatible.
5. Redact hook and upstream error logs before writing them to disk.
6. Add CI security scanners once Elixir tooling is available: Sobelow, Hex audit, Gitleaks, and dependency update checks.
