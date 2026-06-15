# Ryo Runtime Deployment

This directory is the Symphony-owned runtime configuration for the Ryo Pi deployment.
It uses the runtime engine repository itself as the deployment source of truth.

## Target State

- Runtime engine repo: `yakisoba666rasb-star/symphony`
- Runtime workflow: `/home/ryo/src/symphony/ops/ryo/WORKFLOW.md`
- Runtime workspace root: `/home/ryo/workspaces/symphony`
- Runtime Linear project: `Symphony`
- Runtime repository route: `yakisoba666rasb-star/symphony` -> `Symphony`
- Dynamic repository owners: `yakisoba666rasb-star`, `ryo1111-qqq`

`repository.allowed_owners` permits Linear Project metadata to register repositories for trusted
GitHub owners. `repository.project_routes` remains the explicit override map:

- `yakisoba666rasb-star/symphony` must be in Linear project `Symphony`.
- Repositories whose Linear project description or links contain an allowlisted GitHub URL are
  discovered without restarting the engine.
- Static project routes win when a repository also appears in Linear Project metadata.

Before changing routing or GitHub intake settings, review the engine docs in
`../../elixir/docs/project_routing.md` and
`../../elixir/docs/github_intake_threat_model.md`. They define the resolution order,
allowlisted-owner boundary, and prompt-injection assumptions used by this deployment.

## Install

```bash
sudo mkdir -p /etc/systemd/system/symphony-engine.service.d
install -m 0600 /home/ryo/src/symphony/ops/ryo/symphony.env.example \
  /home/ryo/.config/symphony-ryo/symphony.env
$EDITOR /home/ryo/.config/symphony-ryo/symphony.env
sudo cp /home/ryo/src/symphony/ops/ryo/systemd/symphony-engine.service \
  /etc/systemd/system/symphony-engine.service
sudo cp /home/ryo/src/symphony/ops/ryo/systemd/symphony-engine.service.d/override.conf \
  /etc/systemd/system/symphony-engine.service.d/override.conf
sudo systemctl daemon-reload
/home/ryo/src/symphony/ops/ryo/preflight.sh /home/ryo/src/symphony/ops/ryo/WORKFLOW.md
/home/ryo/src/symphony/ops/ryo/install-logrotate.sh
sudo systemctl restart symphony-engine.service
curl -fsS http://127.0.0.1:4000/api/v1/state
```

`install-logrotate.sh` installs
`ops/ryo/logrotate/symphony-ryo` to `/etc/logrotate.d/symphony-ryo` and
runs `sudo logrotate -d /etc/logrotate.d/symphony-ryo` as a dry-run
validation. This is required for the service stdout/stderr files written by
`StandardOutput=append:` and `StandardError=append:`. If the logrotate config
is not installed, `/var/log/symphony-ryo/engine.log` and
`/var/log/symphony-ryo/engine-error.log` can grow without bound.

## Optional auto-template Integration

The `auto-template.service` drop-in is a host-specific integration for the Ryo
Pi only. It is not required to install or update `symphony-engine.service`, and
the default engine deployment above intentionally does not copy or restart it.

Apply it only on hosts where `auto-template.service` already exists and the
external script path in the drop-in is valid:

```bash
test -f /home/ryo/Github/kasotuosawari-design/auto_template/run_auto_template.py
sudo mkdir -p /etc/systemd/system/auto-template.service.d
sudo cp /home/ryo/src/symphony/ops/ryo/systemd/auto-template.service.d/zz-linear-env.conf \
  /etc/systemd/system/auto-template.service.d/zz-linear-env.conf
sudo systemctl daemon-reload
sudo systemctl restart auto-template.service
```

## Validation

Use the deployment preflight before restarting the service:

```bash
/home/ryo/src/symphony/ops/ryo/preflight.sh /home/ryo/src/symphony/ops/ryo/WORKFLOW.md
```

After a restart, confirm the loopback API is reachable and points at the expected project:

```bash
curl -fsS http://127.0.0.1:4000/api/v1/state
```

## Legacy Lab Cleanup Checklist

1. Merge this deployment change.
2. Confirm `systemctl cat symphony-engine.service` references only `/home/ryo/src/symphony`.
3. Confirm `/api/v1/state` is healthy and the dashboard project is `Symphony`.
4. Move or close remaining active issues from the retired Lab project.
5. Archive the retired GitHub repository instead of deleting it immediately.
6. Keep the archive for at least one runtime cycle before permanent deletion.
