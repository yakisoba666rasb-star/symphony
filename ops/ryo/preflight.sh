#!/usr/bin/env bash
set -euo pipefail

workflow_path="${1:-/home/ryo/src/symphony/ops/ryo/WORKFLOW.md}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow_path="$(realpath "$workflow_path")"

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
