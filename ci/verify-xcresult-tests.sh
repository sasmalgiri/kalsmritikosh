#!/usr/bin/env bash
#
# CI-001A — prove tests ACTUALLY executed, from the result bundle (never from console text).
#
# Reads build/TestResults.xcresult (or $1) via `xcrun xcresulttool get test-results summary`,
# and FAILS the job when:
#   * the bundle is missing / unreadable;
#   * xcresulttool cannot produce a summary (e.g. a build-only, zero-test invocation);
#   * any test failed;
#   * fewer than ci/test-baseline.json:minimumExecutedTests tests executed (a floor, not equality).
#
set -euo pipefail

BUNDLE="${1:-build/TestResults.xcresult}"
BASELINE_FILE="${2:-ci/test-baseline.json}"

if [ ! -e "$BUNDLE" ]; then
  echo "::error::xcresult bundle not found at '$BUNDLE' — tests did not run (or the path is wrong)."
  exit 1
fi

MIN="$(python3 -c "import json,sys; print(json.load(open('$BASELINE_FILE'))['minimumExecutedTests'])" 2>/dev/null || echo "")"
if [ -z "$MIN" ]; then
  echo "::error::could not read minimumExecutedTests from '$BASELINE_FILE'."
  exit 1
fi

SUMMARY_JSON="$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json 2>/dev/null || true)"
if [ -z "$SUMMARY_JSON" ]; then
  echo "::error::xcresulttool produced no test-results summary — the bundle has no executed tests."
  exit 1
fi

# Parse the summary and enforce the invariants. Exit codes: 0 pass; 2 zero/under-floor; 3 failures.
# The summary JSON is passed via env (not stdin) so it can't collide with the heredoc program.
MIN="$MIN" SUMMARY_JSON="$SUMMARY_JSON" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["SUMMARY_JSON"])
minimum = int(os.environ["MIN"])
total   = int(data.get("totalTestCount", 0))
failed  = int(data.get("failedTests", 0))
skipped = int(data.get("skippedTests", 0))
passed  = int(data.get("passedTests", 0))
result  = data.get("result", "Unknown")
print(f"xcresult summary: result={result} total={total} passed={passed} failed={failed} skipped={skipped} (floor={minimum})")
if total == 0:
    print("::error::zero tests executed — a build-only or empty run cannot satisfy the test gate.")
    sys.exit(2)
if total < minimum:
    print(f"::error::only {total} tests executed, below the required floor of {minimum}.")
    sys.exit(2)
if failed > 0 or result != "Passed":
    print(f"::error::{failed} test(s) failed (result={result}).")
    sys.exit(3)
print(f"OK — {total} tests executed, 0 failed (>= floor {minimum}).")
PY
