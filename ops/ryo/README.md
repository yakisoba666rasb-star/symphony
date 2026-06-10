# Ryo Runtime Deployment

This directory is the Symphony-owned runtime configuration for the Ryo Pi deployment.
It uses the runtime engine repository itself as the deployment source of truth.

## Target State

- Runtime engine repo: `yakisoba666rasb-star/symphony`
- Runtime workflow: `/home/ryo/src/symphony/ops/ryo/WORKFLOW.md`
- Runtime workspace root: `/home/ryo/workspaces/symphony`
- Runtime Linear project: `Symphony`
- Runtime repository route: `yakisoba666rasb-star/symphony` -> `Symphony`

`repository.project_routes` keeps repository/project ownership explicit:

- `yakisoba666rasb-star/symphony` must be in Linear project `Symphony`.
- Repositories whose Linear project does not match the repository name must
  provide their own explicit route before dispatch.

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

## Legacy Lab Cleanup Checklist

1. Merge this deployment change.
2. Confirm `systemctl cat symphony-engine.service` references only `/home/ryo/src/symphony`.
3. Confirm `/api/v1/state` is healthy and the dashboard project is `Symphony`.
4. Move or close remaining active issues from the retired Lab project.
5. Archive the retired GitHub repository instead of deleting it immediately.
6. Keep the archive for at least one runtime cycle before permanent deletion.
