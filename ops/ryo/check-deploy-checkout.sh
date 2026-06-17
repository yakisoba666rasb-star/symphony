#!/usr/bin/env bash
set -euo pipefail

deploy_root="${1:-${SYMPHONY_DEPLOY_ROOT:-/home/ryo/src/symphony}}"
expected_branch="${SYMPHONY_DEPLOY_BRANCH:-main}"
expected_remote="${SYMPHONY_DEPLOY_REMOTE:-origin}"
check_remote_ref="${SYMPHONY_DEPLOY_CHECK_REMOTE_REF:-1}"

fail() {
  printf 'DEPLOY_CHECKOUT\nROOT: %s\nOK: false\nERROR: %s\n' "$deploy_root" "$1" >&2
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

if ! branch="$(git -C "$deploy_root" symbolic-ref -q --short HEAD)"; then
  fail "deploy checkout must not be detached"
fi

if [[ "$branch" != "$expected_branch" ]]; then
  fail "deploy checkout must be on $expected_branch, got $branch"
fi

status="$(git -C "$deploy_root" status --porcelain --untracked-files=normal)"
if [[ -n "$status" ]]; then
  printf 'DEPLOY_CHECKOUT\nROOT: %s\nOK: false\nERROR: deploy checkout is dirty\nSTATUS:\n%s\n' "$deploy_root" "$status" >&2
  exit 1
fi

head_sha="$(git -C "$deploy_root" rev-parse HEAD)"
remote_ref="refs/remotes/$expected_remote/$expected_branch"

if [[ "$check_remote_ref" != "0" ]]; then
  if ! remote_sha="$(git -C "$deploy_root" rev-parse --verify "$remote_ref^{commit}" 2>/dev/null)"; then
    fail "remote tracking ref not found: $remote_ref; run git fetch $expected_remote first"
  fi

  if [[ "$head_sha" != "$remote_sha" ]]; then
    fail "deploy checkout HEAD $head_sha does not match $remote_ref $remote_sha; run ops/ryo/deploy-main.sh"
  fi
fi

printf 'DEPLOY_CHECKOUT\nROOT: %s\nBRANCH: %s\nHEAD: %s\nOK: true\n' "$deploy_root" "$branch" "$head_sha"
