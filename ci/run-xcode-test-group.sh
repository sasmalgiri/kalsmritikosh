#!/usr/bin/env bash
#
# CI-001B — run one specialized test group defined by a manifest, into isolated build paths, then
# verify its .xcresult. Each group gets its own DerivedData / result bundle / logs so the jobs are
# independent and parallelizable.
#
# Usage: ci/run-xcode-test-group.sh ci/test-groups/<group>.json
#
set -euo pipefail   # pipefail => every `| tee` pipeline propagates the real exit code

GROUP_JSON="${1:?group manifest required}"
GROUP="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['group'])" "$GROUP_JSON")"
OUT="build/${GROUP}"
rm -rf "$OUT"; mkdir -p "$OUT"

# Build the -only-testing arguments from the manifest selectors (bash 3.2-safe: no mapfile).
ONLY=()
while IFS= read -r sel; do
  [ -n "$sel" ] && ONLY+=("-only-testing:${sel}")
done < <(python3 -c "import json,sys; [print(s) for s in json.load(open(sys.argv[1]))['selectors']]" "$GROUP_JSON")

# Same labelled runner-OS deployment-target compatibility override as the full-suite job: the hosted
# macOS 26 runner can be a point release below the pinned test deployment target, which blocks test
# EXECUTION. This is a compatibility override within the macOS 26 floor, NOT proof the pinned point
# release passed.
DEPLOY="$(sw_vers -productVersion | cut -d. -f1-2)"
echo "[${GROUP}] runner macOS $(sw_vers -productVersion) — MACOSX_DEPLOYMENT_TARGET=${DEPLOY}; ${#ONLY[@]} selectors"

xcodebuild \
  -project Kalsmritikosh.xcodeproj \
  -scheme Kalsmritikosh \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${OUT}/DerivedData" \
  -resultBundlePath "${OUT}/Results.xcresult" \
  -skipMacroValidation \
  MACOSX_DEPLOYMENT_TARGET="${DEPLOY}" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY[@]}" \
  test 2>&1 | tee "${OUT}/test.log"

bash ci/verify-xcresult-group.sh "$GROUP_JSON" "${OUT}/Results.xcresult" 2>&1 | tee "${OUT}/verify.log"
