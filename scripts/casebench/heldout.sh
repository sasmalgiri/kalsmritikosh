#!/usr/bin/env bash
# Held-out accuracy run (F5/B6) — versioned, reproducible driver for the chronology bench.
#
#   scripts/casebench/heldout.sh SET [--generate SEED] [--paths rules,claude] [--workers N] [--tag T]
#
# SET        a name under $CASEBENCH_HOME (default ~/CaseBench), e.g. ho9-chron (regression) or ho10-chron
# --generate generate SET first from public DOJ releases ($CASEBENCH_HOME/raw) with SEED, skipping every
#            prosecution already used by earlier sets ($CASEBENCH_HOME/skip-chron); then 2 paraphrases each
# --paths    which answer paths to run: rules (AI off), claude (cloud composition with a PUBLIC-DATA bench
#            key read from $CASEBENCH_CLOUD_KEY_FILE — never committed, never used on owner data)
# --tag      suffix for the results folders (results-<path><tag>), so a re-run never overwrites
#
# What it records next to the results: the commit, the scorer's SHA-256, the build settings and the
# exact command — the release packet's "measurement inputs". It builds an unsigned test host from a
# clean worktree of HEAD (so uncommitted edits are never measured), runs the shards, then scores with
# ccsscore.py and builds the blinded adjudication pack. A launch failure is reported, never scored as 0.
#
# Run it from Terminal on a Mac logged in to a GUI session: the test runner needs a terminal session
# that may launch apps (an agent sandbox without one fails with "Pseudo Terminal Setup Error").
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOME_DIR=${CASEBENCH_HOME:-$HOME/CaseBench}
SET=${1:?set name}; shift
SEED=""; PATHS="rules,claude"; WORKERS=2; TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --generate) SEED=$2; shift 2;;
    --paths) PATHS=$2; shift 2;;
    --workers) WORKERS=$2; shift 2;;
    --tag) TAG=$2; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
L="$HOME_DIR/$SET"; mkdir -p "$L"
cd "$REPO"

if [ -n "$SEED" ]; then
  python3 scripts/casebench/chronology.py --raw "$HOME_DIR/raw" --out "$L/src" --render build/casebench-render \
    --cases 60 --seed "$SEED" --skip-keys "$HOME_DIR/skip-chron" > "$L/gen.log" 2>&1
  python3 scripts/casebench/paraphrase.py "$L/src" "$L/cases" --per 2 > "$L/para.log" 2>&1
fi
[ -d "$L/cases" ] || { echo "no cases under $L/cases" >&2; exit 1; }

SHA=$(git rev-parse --short HEAD)
DD="$REPO/build/dd-heldout-$SHA"
if [ ! -d "$DD/Build/Products" ]; then
  WT="$HOME_DIR/src-wt-$SHA"
  git worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$WT"
  git worktree add --detach "$WT" "$SHA" > "$L/build-$SHA.log" 2>&1
  (cd "$WT" && xcodebuild build-for-testing -scheme Kalsmritikosh -destination platform=macOS,arch=arm64 \
     -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >> "$L/build-$SHA.log" 2>&1) || { echo "build failed: $L/build-$SHA.log" >&2; exit 1; }
  git worktree remove --force "$WT" 2>/dev/null || true
fi

SCORER_SHA=$(shasum -a 256 scripts/casebench/ccsscore.py scripts/casebench/score.py | shasum -a 256 | cut -c1-64)
for P in ${PATHS//,/ }; do
  OUT="$L/results-$P$TAG"
  {
    echo "commit: $SHA"; echo "scorer-sha256: $SCORER_SHA"; echo "path: $P"; echo "workers: $WORKERS"
    echo "host: $(sysctl -n hw.model) macOS $(sw_vers -productVersion)"; echo "started: $(date -u +%FT%TZ)"
    echo "command: $0 $SET --paths $PATHS --workers $WORKERS --tag '$TAG'"
  } > "$L/MEASUREMENT-$P$TAG.txt"
  if [ "$P" = claude ]; then
    : "${CASEBENCH_CLOUD_KEY_FILE:?set CASEBENCH_CLOUD_KEY_FILE to the public-data bench key file}"
    export TEST_RUNNER_CASEBENCH_CLOUD_KEY_FILE="$CASEBENCH_CLOUD_KEY_FILE"
  else
    unset TEST_RUNNER_CASEBENCH_CLOUD_KEY_FILE
  fi
  TEST_RUNNER_CASEBENCH_FULL=1 TEST_RUNNER_CASEBENCH_WORKFLOW_EVERY=0 TEST_RUNNER_CASEBENCH_ASK_EVERY=1 DD="$DD" \
    caffeinate -i scripts/casebench/run.sh "$L/cases" "$OUT" "$WORKERS" 1 > "$L/run-$P$TAG.log" 2>&1 || true
  N=$(ls "$OUT"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  if [ "$N" = 0 ]; then
    echo "$P: no shard ran — see $OUT/.workers/*.log (launch failure, not a score)" | tee -a "$L/MEASUREMENT-$P$TAG.txt" >&2
    continue
  fi
  python3 scripts/casebench/ccsscore.py "$L/cases" "$OUT" > "$L/score-$P$TAG.txt"
  python3 scripts/casebench/adjudication_pack.py "$L/cases" "$OUT" "$HOME_DIR/adjudication" --label "$SET-$P$TAG"
  echo "finished: $(date -u +%FT%TZ)" >> "$L/MEASUREMENT-$P$TAG.txt"
done
