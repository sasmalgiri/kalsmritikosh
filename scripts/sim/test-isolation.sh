#!/usr/bin/env bash
# Unified path R2-E — SIMULATED test-isolation audit (QA-14).
# Lists the owner's real app folders (names, sizes and modification times only — never content) before and after a
# small test run, and fails when the run changed anything there; then checks the run's result bundle is fresh (newer
# than HEAD's commit), executed tests > 0 and none were counted as passed while skipped. A fresh CI run of HEAD after a
# push is still needed for release.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/test-isolation.md"
sim_banner "$R" "test isolation and real execution"
CONTAINER="$HOME/Library/Containers/ecosanskritiinnovation.Kalsmritikosh/Data"
snapshot() {
  for d in "$CONTAINER/Library/Application Support" "$CONTAINER/Documents"; do
    [ -d "$d" ] && find "$d" -maxdepth 3 -type f -not -path "*/KalsmritikoshTests*" -not -path "*/TestHost*" -exec stat -f '%m %z %N' {} + 2>/dev/null
  done | sort
}
BEFORE="$(snapshot | shasum -a 256 | awk '{print $1}')"
bundle="$SIM_DERIVED/isolation.xcresult"
set +e
TEST_RUNNER_KALS_SIM_OUT="$SIM_OUT" xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' -derivedDataPath "$SIM_DERIVED" \
  -resultBundlePath "$bundle" -only-testing:KalsmritikoshTests/TestHostIsolationTests -only-testing:KalsmritikoshTests/SimulatedTeamIdentityTests \
  > "$SIM_DERIVED.isolation.log" 2>&1
set -e
AFTER="$(snapshot | shasum -a 256 | awk '{print $1}')"
status=0
if [ "$BEFORE" = "$AFTER" ]; then echo "- the owner's app folders are unchanged by the run (listing hash $BEFORE)" >> "$R"
else echo "- FAILED: the run changed files in the owner's app folders" >> "$R"; status=1; fi
COMMIT_TS="$(git log -1 --format=%ct)"
if [ -d "$bundle" ]; then
  BUNDLE_TS="$(stat -f %m "$bundle")"
  [ "$BUNDLE_TS" -ge "$COMMIT_TS" ] && echo "- the result bundle is newer than HEAD's commit" >> "$R" || { echo "- FAILED: stale result bundle" >> "$R"; status=1; }
  xcrun xcresulttool get test-results summary --path "$bundle" --format json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=d.get("passedTests",0); s=d.get("skippedTests",0); f=d.get("failedTests",0)
print("- executed: %d passed, %d failed; %d skipped (not counted as run)" % (p, f, s))
sys.exit(0 if p > 0 and f == 0 else 1)' >> "$R" || status=1
else echo "- FAILED: no result bundle (the runner did not start)" >> "$R"; status=1; fi
if grep -q "hung before" "$SIM_DERIVED.isolation.log" 2>/dev/null; then echo "- FAILED: the runner reported \"hung before\" — not a fresh pass" >> "$R"; status=1; fi
rm -f "$SIM_DERIVED.isolation.log"
sim_cleanup_derived
exit $status
