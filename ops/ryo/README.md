# Ryo Runtime Deployment

This directory is the Symphony-owned runtime configuration for the Ryo Pi deployment.
It replaces the previous dependency on `yakisoba666rasb-star/Symphony-Ryo-Lab` as
the runtime configuration repository.

## Target State

- Runtime engine repo: `yakisoba666rasb-star/symphony`
- Runtime workflow: `/home/ryo/src/symphony/ops/ryo/WORKFLOW.md`
- Runtime workspace root: `/home/ryo/workspaces/symphony`
- Runtime Linear project: `Symphony`
- Legacy Lab repo dispatch: disabled by route alias mismatch

`repository.project_routes` keeps repository/project ownership explicit:

- `yakisoba666rasb-star/symphony` must be in Linear project `Symphony`.
- `yakisoba666rasb-star/Symphony-Ryo-Lab` maps to
  `ArchivedSymphonyRyoLabDoNotDispatch`, which intentionally matches no active
  Linear project after the Lab repo is retired.

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
sudo mkdir -p /etc/systemd/system/auto-template.service.d
sudo cp /home/ryo/src/symphony/ops/ryo/systemd/auto-template.service.d/zz-linear-env.conf \
  /etc/systemd/system/auto-template.service.d/zz-linear-env.conf
sudo systemctl daemon-reload
/home/ryo/src/symphony/ops/ryo/preflight.sh /home/ryo/src/symphony/ops/ryo/WORKFLOW.md
sudo systemctl restart symphony-engine.service
sudo systemctl restart auto-template.service
curl -fsS http://127.0.0.1:4000/api/v1/state
```

## Archive Checklist For `Symphony-Ryo-Lab`

1. Merge this deployment change.
2. Confirm `systemctl cat symphony-engine.service` references only `/home/ryo/src/symphony`.
3. Confirm `/api/v1/state` is healthy and the dashboard project is `Symphony`.
4. Move or close remaining active `Symphony-Ryo-Lab` Linear issues.
5. Archive the GitHub repository instead of deleting it immediately.
6. Keep the archive for at least one runtime cycle before permanent deletion.
