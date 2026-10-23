#!/usr/bin/env bash
# The end-to-end bench, one category at a time: build the category's cases (up to PER), run them
# through the app (documents read, every ASK-th case asked archive-wide, every WF-th case worked
# as an investigation), then delete the generated documents (truth.jsonl and results are kept)
# so the disk never holds more than one category. Safe to re-run: a finished category is skipped.
#   scripts/casebench/e2e-run.sh ROOT WORKERS PER ASK WF [CATEGORY...]
set -uo pipefail
ROOT=${1:?root}; WORKERS=${2:-2}; PER=${3:-10000}; ASK=${4:-10}; WF=${5:-10}; shift 5 || true
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
CATS=("$@")
[ ${#CATS[@]} -eq 0 ] && CATS=(fda-drug-recall fda-device-recall fda-food-recall nhtsa-defect court-criminal court-civil
                              ntsb-aviation osha-workplace doj-police-misconduct doj-health-care-and-pharma-fraud
                              doj-drug-trafficking doj-violent-crime doj-financial-fraud doj-cybercrime
                              doj-public-corruption doj-environmental-crime doj-tax-crime doj-immigration-crime
                              doj-other-federal-crime)
mkdir -p "$ROOT/cases" "$ROOT/results"
for cat in "${CATS[@]}"; do
  mark="$ROOT/cases/.done-$cat"
  [ -f "$mark" ] && continue
  echo "$(date '+%F %T') building $cat"
  python3 "$HERE/e2e.py" --raw "$HOME/CaseBench/raw" --cap "$HOME/CaseBench/cases" --src "$HOME/CaseBench/ai1000/src" \
      --out "$ROOT/cases" --render "$REPO/build/casebench-render" --per "$PER" --only "$cat" || continue
  echo "$(date '+%F %T') running $cat"
  (cd "$REPO" && TEST_RUNNER_CASEBENCH_WORKFLOW_EVERY=$WF TEST_RUNNER_CASEBENCH_ASK_EVERY=$ASK DD=${DD:-build/dd2} \
      scripts/casebench/run.sh "$ROOT/cases/$cat" "$ROOT/results" "$WORKERS" 1) || true
  find "$ROOT/cases/$cat" -mindepth 2 -maxdepth 2 -type d -exec rm -rf {} + 2>/dev/null
  touch "$mark"
  echo "$(date '+%F %T') done $cat — $(ls "$ROOT/results"/*.jsonl 2>/dev/null | wc -l | tr -d ' ') shard results; $(df -h ~ | tail -1 | awk '{print $4}') free"
done
