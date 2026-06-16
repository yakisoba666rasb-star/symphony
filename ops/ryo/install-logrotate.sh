#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_path="$repo_root/ops/ryo/logrotate/symphony-ryo"
target_path="/etc/logrotate.d/symphony-ryo"
runtime_user="ryo"
runtime_group="ryo"
log_dir="/var/log/symphony-ryo"

if [[ ! -f "$source_path" ]]; then
  printf 'ERROR: logrotate source config not found: %s\n' "$source_path" >&2
  exit 1
fi

for command_name in sudo install logrotate; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done

printf 'Creating runtime log directory: %s\n' "$log_dir"
sudo install -d -m 0755 -o "$runtime_user" -g "$runtime_group" "$log_dir"

printf 'Installing logrotate config: %s -> %s\n' "$source_path" "$target_path"
sudo install -m 0644 -o root -g root "$source_path" "$target_path"

printf 'Validating installed config with logrotate dry-run: %s\n' "$target_path"
sudo logrotate -d "$target_path"

printf 'Installed and validated logrotate config: %s\n' "$target_path"
