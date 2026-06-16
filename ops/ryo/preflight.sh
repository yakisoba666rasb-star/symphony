#!/usr/bin/env bash
set -euo pipefail

workflow_path="${1:-/home/ryo/src/symphony/ops/ryo/WORKFLOW.md}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow_path="$(realpath "$workflow_path")"
runtime_user="ryo"
log_dir="/var/log/symphony-ryo"

if [[ ! -d "$log_dir" ]]; then
  printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: log directory not found: %s\n' "$workflow_path" "$log_dir" >&2
  exit 1
fi

if ! id "$runtime_user" >/dev/null 2>&1; then
  printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: runtime user not found: %s\n' "$workflow_path" "$runtime_user" >&2
  exit 1
fi

runtime_uid="$(id -u "$runtime_user")"
current_uid="$(id -u)"

if [[ "$current_uid" == "$runtime_uid" ]]; then
  if [[ ! -w "$log_dir" ]]; then
    printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: log directory is not writable by %s: %s\n' "$workflow_path" "$runtime_user" "$log_dir" >&2
    exit 1
  fi
elif command -v sudo >/dev/null 2>&1; then
  if ! sudo -u "$runtime_user" test -w "$log_dir"; then
    printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: log directory is not writable by %s: %s\n' "$workflow_path" "$runtime_user" "$log_dir" >&2
    exit 1
  fi
else
  printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: cannot verify log directory writability as %s because sudo is unavailable\n' "$workflow_path" "$runtime_user" >&2
  exit 1
fi

if [[ ! -f "$workflow_path" ]]; then
  printf 'WORKFLOW_PREFLIGHT\nWORKFLOW: %s\nOK: false\nERROR: workflow file not found\n' "$workflow_path" >&2
  exit 1
fi

cd "$repo_root/elixir"
SYMPHONY_PREFLIGHT_WORKFLOW="$workflow_path" mise exec -- mix run --no-start -e '
workflow = System.fetch_env!("SYMPHONY_PREFLIGHT_WORKFLOW")
SymphonyElixir.Workflow.set_workflow_file_path(workflow)

case SymphonyElixir.Config.validate!() do
  :ok ->
    IO.puts("WORKFLOW_PREFLIGHT")
    IO.puts("WORKFLOW: " <> workflow)
    IO.puts("OK: true")

  {:error, reason} ->
    IO.puts("WORKFLOW_PREFLIGHT")
    IO.puts("WORKFLOW: " <> workflow)
    IO.puts("OK: false")
    IO.puts("ERROR: " <> inspect(reason))
    System.halt(1)
end
'
