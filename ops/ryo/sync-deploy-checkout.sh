#!/usr/bin/env bash
set -euo pipefail

deploy_root="${1:-${SYMPHONY_DEPLOY_ROOT:-/home/ryo/src/symphony}}"
branch="${SYMPHONY_DEPLOY_BRANCH:-main}"
remote="${SYMPHONY_DEPLOY_REMOTE:-origin}"

fail() {
  printf 'SYNC_DEPLOY_CHECKOUT\nROOT: %s\nOK: false\nERROR: %s\n' "$deploy_root" "$1" >&2
  exit 1
}

deploy_root="$(realpath "$deploy_root")"

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
  printf 'SYNC_DEPLOY_CHECKOUT\nROOT: %s\nOK: false\nERROR: refusing to update dirty deploy checkout\nSTATUS:\n%s\n' "$deploy_root" "$status" >&2
  exit 1
fi

git -C "$deploy_root" fetch --prune "$remote"

if ! git -C "$deploy_root" switch "$branch"; then
  git -C "$deploy_root" switch -c "$branch" "$remote/$branch"
fi

git -C "$deploy_root" pull --ff-only "$remote" "$branch"

head_sha="$(git -C "$deploy_root" rev-parse HEAD)"
printf 'SYNC_DEPLOY_CHECKOUT\nROOT: %s\nBRANCH: %s\nHEAD: %s\nOK: true\n' "$deploy_root" "$branch" "$head_sha"
