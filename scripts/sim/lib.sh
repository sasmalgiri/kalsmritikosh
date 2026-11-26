#!/usr/bin/env bash
# Unified path R2-E (owner 2026-11-22 round 2) — shared helpers for the SIMULATED release runs under scripts/sim/.
# Every report these scripts write starts with "SIMULATED" and ends with what a real run still needs.
# Outputs are small text files under $SIM_OUT (default release/simulated/<UTC date>/); build products go to a
# temporary DerivedData under $TMPDIR that is deleted at the end (disk is tight; never another project's DerivedData).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
SIM_DATE="$(date -u +%Y-%m-%d)"
SIM_OUT="${SIM_OUT:-$ROOT/release/simulated/$SIM_DATE}"
mkdir -p "$SIM_OUT"
SIM_DERIVED="${SIM_DERIVED:-${TMPDIR:-/tmp}/kals-sim-derived}"
SCHEME="${SCHEME:-Kalsmritikosh}"
PROJECT="$ROOT/Kalsmritikosh.xcodeproj"

sim_banner() {  # $1 = report file, $2 = title
  {
    echo "# SIMULATED — $2"
    echo
    echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) at $(git rev-parse HEAD 2>/dev/null || echo unknown)."
    echo "This is a local simulation, not a release observation. Real people, accounts, a signed build and a server are still needed for release."
    echo
  } > "$1"
}

sim_cleanup_derived() { rm -rf "$SIM_DERIVED"; }

# Run named test suites/tests in the test host; writes the .xcresult into $SIM_DERIVED and a summary line into $1.
# usage: sim_run_tests <report> <selector> [<selector> ...]   (selector: KalsmritikoshTests/Suite[/test()])
sim_run_tests() {
  local report="$1"; shift
  local args=() bundle="$SIM_DERIVED/results-$RANDOM.xcresult"
  for s in "$@"; do args+=("-only-testing:$s"); done
  set +e
  TEST_RUNNER_KALS_SIM_OUT="$SIM_OUT" xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' \
    -derivedDataPath "$SIM_DERIVED" -resultBundlePath "$bundle" "${args[@]}" > "$SIM_DERIVED/xcodebuild-$RANDOM.log" 2>&1
  local rc=$?
  set -e
  local summary
  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --format json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("result=%s passed=%s failed=%s skipped=%s" % (d.get("result"), d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))' 2>/dev/null || echo "no result bundle")"
  echo "- \`$*\`: exit $rc, $summary" >> "$report"
  return $rc
}
