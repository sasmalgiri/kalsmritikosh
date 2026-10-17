#!/bin/bash
# Run the whole KalsmritikoshTests target as BATCHES of suites, each in a fresh test host,
# then merge the result bundles into one .xcresult for ci/verify-xcresult-tests.sh.
#
# Why batches: Swift Testing starts every test in the host at once. With ~5,000 tests on a
# 3-core runner, wall-clock time per test stretches until a test with a `.timeLimit` expires;
# xcodebuild then kills the host and every test still in flight in it is recorded as failed
# (832 at once on 2026-10-17). A batch keeps contention bounded, and a host restart costs
# only that batch. Every test still runs; nothing is skipped.
#
# usage: ci/run-tests-batched.sh <derivedDataPath> <output.xcresult> [batches]
set -uo pipefail

DERIVED="$1"
OUT="$2"
BATCHES="${3:-10}"
WORK="$(dirname "$OUT")/batches"
COMMON=(-project Kalsmritikosh.xcodeproj -scheme Kalsmritikosh -configuration Debug
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" -skipMacroValidation)
# CI builds unsigned. KALS_SIGNED=1 keeps the project's signing for a local run (an unsigned host
# cannot read a repository kept under ~/Downloads, which privacy protection guards).
[ "${KALS_SIGNED:-0}" = 1 ] || COMMON+=(CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO)

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK"

echo "== build-for-testing"
xcodebuild "${COMMON[@]}" build-for-testing > "$WORK/build-for-testing.log" 2>&1 \
  || { tail -50 "$WORK/build-for-testing.log"; echo "::error::build-for-testing failed"; exit 1; }

echo "== enumerate"
xcodebuild "${COMMON[@]}" test-without-building -enumerate-tests \
  -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path "$WORK/tests.json" > "$WORK/enumerate.log" 2>&1 \
  || { tail -50 "$WORK/enumerate.log"; echo "::error::test enumeration failed"; exit 1; }

python3 - "$WORK/tests.json" "$WORK" "$BATCHES" <<'PY'
import json, sys
path, work, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path))
ids = [t["identifier"] for v in d["values"] for t in v["enabledTests"] + v.get("disabledTests", [])]
suites = sorted({"/".join(i.split("/")[:2]) for i in ids if i.count("/") >= 2})
if not suites:
    sys.exit("no suites enumerated")
# Round-robin over the sorted list keeps related (alphabetically adjacent) heavy suites apart.
for b in range(n):
    with open(f"{work}/batch-{b + 1}.txt", "w") as f:
        f.write("\n".join(suites[b::n]) + "\n")
print(f"{len(ids)} tests in {len(suites)} suites -> {n} batches")
PY
[ $? -eq 0 ] || { echo "::error::could not split the suites into batches"; exit 1; }

failed=0
for n in $(seq 1 "$BATCHES"); do
  b="batch-$n"
  list="$WORK/$b.txt"
  args=()
  while IFS= read -r s; do [ -n "$s" ] && args+=("-only-testing:$s"); done < "$list"
  echo "== $b (${#args[@]} suites) $(date +%H:%M:%S)"
  if xcodebuild "${COMMON[@]}" test-without-building "${args[@]}" \
       -resultBundlePath "$WORK/$b.xcresult" > "$WORK/$b.log" 2>&1; then
    echo "   passed"
  else
    failed=1
    echo "::error::$b failed"
    grep -E "Test case .*' failed|hung before|Restarting after" "$WORK/$b.log" | sort -u | head -40
  fi
  # The console log of every batch is uploaded as one test.log.
  cat "$WORK/$b.log" >> test.log
done

echo "== merge"
bundles=("$WORK"/batch-*.xcresult)
xcrun xcresulttool merge "${bundles[@]}" --output-path "$OUT" \
  || { echo "::error::could not merge the batch result bundles"; exit 1; }

exit $failed
