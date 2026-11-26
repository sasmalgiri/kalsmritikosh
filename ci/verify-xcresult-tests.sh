#!/usr/bin/env bash
#
# CI-001A — prove tests ACTUALLY executed, from the result bundle (never from console text).
#
# Reads build/TestResults.xcresult (or $1) via `xcrun xcresulttool get test-results summary`,
# and FAILS the job when:
#   * the bundle is missing / unreadable;
#   * xcresulttool cannot produce a summary (e.g. a build-only, zero-test invocation);
#   * any test failed;
#   * fewer than ci/test-baseline.json:minimumExecutedTests tests executed (a floor, not equality);
#   * S18 (QA-14): SKIPPED tests are not executed tests — the floor counts passed + failed + expected failures only,
#     so a run whose tests were all skipped cannot meet it;
#   * S18 (QA-14): the bundle STARTED before the commit it is checked for (HEAD's committer time, or $XCRESULT_NOT_BEFORE
#     as epoch seconds): an old bundle left on disk is not a fresh pass. XCRESULT_ALLOW_STALE=1 skips only this check.
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

NOT_BEFORE="${XCRESULT_NOT_BEFORE:-}"
if [ -z "$NOT_BEFORE" ] && [ "${XCRESULT_ALLOW_STALE:-0}" != "1" ]; then
  NOT_BEFORE="$(git log -1 --format=%ct 2>/dev/null || echo "")"
fi
[ "${XCRESULT_ALLOW_STALE:-0}" = "1" ] && NOT_BEFORE=""

# Parse the summary and enforce the invariants. Exit codes: 0 pass; 2 zero/under-floor; 3 failures.
# The summary JSON is passed via env (not stdin) so it can't collide with the heredoc program.
MIN="$MIN" SUMMARY_JSON="$SUMMARY_JSON" NOT_BEFORE="$NOT_BEFORE" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["SUMMARY_JSON"])
minimum = int(os.environ["MIN"])
total   = int(data.get("totalTestCount", 0))
failed  = int(data.get("failedTests", 0))
skipped = int(data.get("skippedTests", 0))
passed  = int(data.get("passedTests", 0))
expected = int(data.get("expectedFailures", 0))
result  = data.get("result", "Unknown")
executed = passed + failed + expected
print(f"xcresult summary: result={result} total={total} executed={executed} passed={passed} failed={failed} skipped={skipped} (floor={minimum})")
if total == 0 or executed == 0:
    print("::error::zero tests executed — a build-only, empty or all-skipped run cannot satisfy the test gate.")
    sys.exit(2)
if executed < minimum:
    print(f"::error::only {executed} tests executed (skipped ones do not count), below the required floor of {minimum}.")
    sys.exit(2)
not_before = os.environ.get("NOT_BEFORE", "").strip()
start = data.get("startTime")
if not_before:
    if start is None:
        print("::error::the bundle records no start time, so it cannot be shown to be fresh (set XCRESULT_ALLOW_STALE=1 to skip).")
        sys.exit(4)
    if float(start) + 1 < float(not_before):
        print(f"::error::stale result bundle: it started at {start}, before the checked commit ({not_before}). An old bundle is not a fresh pass.")
        sys.exit(4)
if failed > 0 or result != "Passed":
    print(f"::error::{failed} test(s) failed (result={result}).")
    sys.exit(3)
print(f"OK — {total} tests executed, 0 failed (>= floor {minimum}).")
PY
