#!/usr/bin/env bash
# Run every architecture guard. Any failure fails the whole check (aggregated, so a run reports
# ALL violations, not just the first). Runnable locally: `bash ci/guards/run-all.sh`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARDS=(
  capability-discipline.sh
  no-try-fatalerror.sh
  no-network-evidence-layers.sh
  no-synthetic-questions-answer-path.sh
  sensitive-scope-mutation-bypass.sh
  release-configuration.sh
  persona-neutral-truth.sh
)
rc=0
for g in "${GUARDS[@]}"; do
  echo "── guard: $g ──"
  bash "$HERE/$g" || rc=1
done
if [ "$rc" -ne 0 ]; then
  echo "::error::One or more architecture guards failed."
  exit 1
fi
echo "All architecture guards clean."
