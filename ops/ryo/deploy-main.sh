#!/usr/bin/env bash
set -euo pipefail

deploy_root="${SYMPHONY_DEPLOY_ROOT:-/home/ryo/src/symphony}"
branch="${SYMPHONY_DEPLOY_BRANCH:-main}"
remote="${SYMPHONY_DEPLOY_REMOTE:-origin}"
service="${SYMPHONY_DEPLOY_SERVICE:-symphony-engine.service}"
workflow_path="$deploy_root/ops/ryo/WORKFLOW.md"
health_url="${SYMPHONY_DEPLOY_HEALTH_URL:-http://127.0.0.1:4000/api/v1/state}"

fail() {
  printf 'DEPLOY_MAIN\nROOT: %s\nOK: false\nERROR: %s\n' "$deploy_root" "$1" >&2
  exit 1
}

deploy_root="$(realpath "$deploy_root")"
workflow_path="$deploy_root/ops/ryo/WORKFLOW.md"

if [[ ! -d "$deploy_root" ]]; then
  fail "deploy root not found"
fi

if ! git -C "$deploy_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "deploy root is not a git worktree"
fi

repo_root="$(git -C "$deploy_root" rev-parse --show-toplevel)"
repo_root="$(realpath "$repo_root")"
if [[ "$repo_root" != "$deploy_root" ]]; then
  fail "deploy root must be the repository root, got git root: $repo_root"
fi

status="$(git -C "$deploy_root" status --porcelain --untracked-files=normal)"
if [[ -n "$status" ]]; then
  printf 'DEPLOY_MAIN\nROOT: %s\nOK: false\nERROR: refusing to update dirty deploy checkout\nSTATUS:\n%s\n\n' "$deploy_root" "$status" >&2
  printf 'Resolve this before deployment: commit it, move it to a worktree, or stash it with:\n' >&2
  printf '  git -C %q stash push -u -m %q\n' "$deploy_root" "deploy-backup-$(date -u +%Y%m%dT%H%M%SZ)" >&2
  exit 1
fi

git -C "$deploy_root" fetch --prune "$remote"
git -C "$deploy_root" switch "$branch"
git -C "$deploy_root" pull --ff-only "$remote" "$branch"

"$deploy_root/ops/ryo/check-deploy-checkout.sh" "$deploy_root"

cd "$deploy_root/elixir"
mise exec -- make build

"$deploy_root/ops/ryo/preflight.sh" "$workflow_path"

sudo systemctl daemon-reload
sudo systemctl restart "$service"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if curl -fsS --max-time 5 "$health_url" >/dev/null; then
    systemctl --no-pager --plain status "$service"
    printf 'DEPLOY_MAIN\nROOT: %s\nBRANCH: %s\nSERVICE: %s\nHEALTH: %s\nOK: true\n' "$deploy_root" "$branch" "$service" "$health_url"
    exit 0
  fi
  sleep 5
done

systemctl --no-pager --plain status "$service" >&2 || true
fail "service restarted but health check did not pass: $health_url"
