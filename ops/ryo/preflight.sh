#!/usr/bin/env bash
set -euo pipefail

workflow_path="${1:-/home/ryo/src/symphony/ops/ryo/WORKFLOW.md}"
env_file="/home/ryo/.config/symphony-ryo/symphony.env"
env_dir="$(dirname "$env_file")"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow_path="$(realpath "$workflow_path")"

if [[ ! -d "$env_dir" ]]; then
  printf 'WORKFLOW_PREFLIGHT\nENV_FILE: %s\nOK: false\nERROR: env directory not found\n' "$env_file" >&2
  exit 1
fi

if [[ ! -f "$env_file" ]]; then
  printf 'WORKFLOW_PREFLIGHT\nENV_FILE: %s\nOK: false\nERROR: env file not found\n' "$env_file" >&2
  exit 1
fi

env_mode="$(stat -c '%a' "$env_file")"
if [[ "$env_mode" != "600" ]]; then
  printf 'WORKFLOW_PREFLIGHT\nENV_FILE: %s\nOK: false\nERROR: env file must use mode 0600, got %s\n' "$env_file" "$env_mode" >&2
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
