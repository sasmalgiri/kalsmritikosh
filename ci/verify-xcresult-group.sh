#!/usr/bin/env bash
#
# CI-001B — verify a specialized test group's .xcresult (never console text). Fails when:
#   * the result bundle is missing / has no summary (zero tests);
#   * fewer than the group's minimumExecutedTests ran (also catches a missing/renamed selector,
#     whose tests then don't run);
#   * any test failed / result != Passed;
#   * a required suite did not run (matched by the type-name prefix of each Test Case identifier).
#
# Usage: ci/verify-xcresult-group.sh <group.json> <Results.xcresult>
#
set -euo pipefail

GROUP_JSON="${1:?group manifest required}"
BUNDLE="${2:?xcresult path required}"

if [ ! -e "$BUNDLE" ]; then
  echo "::error::group result bundle not found: $BUNDLE"
  exit 1
fi

SUMMARY="$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json 2>/dev/null || true)"
if [ -z "$SUMMARY" ]; then
  echo "::error::no test-results summary — the group ran zero tests."
  exit 1
fi
TESTS="$(xcrun xcresulttool get test-results tests --path "$BUNDLE" --format json 2>/dev/null || true)"

GROUP_JSON="$GROUP_JSON" SUMMARY_JSON="$SUMMARY" TESTS_JSON="$TESTS" python3 - <<'PY'
import json, os, sys
cfg     = json.load(open(os.environ["GROUP_JSON"]))
summary = json.loads(os.environ["SUMMARY_JSON"])
tests   = json.loads(os.environ["TESTS_JSON"]) if os.environ.get("TESTS_JSON") else {}

group    = cfg["group"]
floor    = int(cfg["minimumExecutedTests"])
required = cfg["requiredSuites"]
total    = int(summary.get("totalTestCount", 0))
failed   = int(summary.get("failedTests", 0))
result   = summary.get("result", "Unknown")

# The set of suite type-names that actually ran (prefix of each Test Case nodeIdentifier).
ran = set()
def walk(o):
    if isinstance(o, dict):
        if o.get("nodeType") == "Test Case":
            nid = o.get("nodeIdentifier", "")
            if "/" in nid:
                ran.add(nid.split("/", 1)[0])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(tests)

print(f"[{group}] total={total} passed={summary.get('passedTests')} failed={failed} result={result} floor={floor} ranSuites={len(ran)}")

errors = []
if total == 0:
    errors.append("zero tests executed")
if total < floor:
    errors.append(f"only {total} tests ran, below the group floor of {floor} (a missing/renamed selector?)")
if failed > 0 or result != "Passed":
    errors.append(f"{failed} test(s) failed (result={result})")
for s in required:
    if s not in ran:
        errors.append(f"required suite did not run: {s}")

if errors:
    for e in errors:
        print(f"::error::[{group}] {e}")
    sys.exit(1)
print(f"OK [{group}] — {total} tests, all {len(required)} required suites ran, 0 failed.")
PY
