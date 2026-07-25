#!/usr/bin/env bash
#
# MIG-001C — real-archive migration acceptance (owner step).
#
# Validates an owner-supplied SANITIZED archive + manifest, then runs the REAL application
# migration path on a disposable working copy via OwnerArchiveMigrationAcceptanceTests:
#
#   validate archive + manifest (schema fields, personal-data flag, pinned SHA-256)
#   → preserve original hash
#   → create disposable working copy (main + -wal/-shm sidecars)
#   → run the external-archive Xcode test (SchemaMigrations.migrate + preservation checks)
#   → verify the .xcresult executed and passed (>= 1 test, 0 failures)
#   → confirm the original hash remains unchanged
#   → surface the non-sensitive acceptance report
#
# SKIPS cleanly when no archive is supplied (CI never has one) — a skip is NEVER verification.
#
# Usage:
#   ci/migrations/verify-real-archive.sh [archive.sqlite] [manifest.json]
# Defaults: ci/migrations/fixtures/real-history-001.sqlite / .json
#
set -euo pipefail

ARCHIVE="${1:-ci/migrations/fixtures/real-history-001.sqlite}"
MANIFEST="${2:-ci/migrations/fixtures/real-history-001.json}"

if [ ! -f "$ARCHIVE" ] || [ ! -f "$MANIFEST" ]; then
  echo "verify-real-archive: SKIP — no sanitized archive/manifest at '$ARCHIVE' / '$MANIFEST'."
  echo "This is an OWNER step; the skip is never counted as real-data verification."
  echo "Provide a sanitized archive (no private data) + a manifest matching"
  echo "ci/migrations/real-archive-manifest.schema.json to run."
  exit 0
fi

# ── 1. Validate the manifest (required fields, privacy flag, hash pin) ─────────────────────────
ORIG_HASH_BEFORE="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
MANIFEST="$MANIFEST" ORIG_HASH="$ORIG_HASH_BEFORE" python3 - <<'PY'
import json, os, re, sys
m = json.load(open(os.environ["MANIFEST"]))
errors = []
def need(key, typ):
    if key not in m: errors.append(f"missing required field: {key}")
    elif not isinstance(m[key], typ): errors.append(f"{key} has wrong type")
need("fixtureID", str); need("originalSchemaVersion", int); need("sanitizerVersion", str)
need("containsPersonalData", bool); need("sourceDatabaseSHA256", str)
need("expectedEndVersion", int); need("expectedCounts", dict); need("representative", dict)
if m.get("containsPersonalData") is not False:
    errors.append("containsPersonalData MUST be false — sanitized fixtures only")
sha = m.get("sourceDatabaseSHA256", "")
if not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
    errors.append("sourceDatabaseSHA256 is not 64 hex chars")
elif sha.lower() != os.environ["ORIG_HASH"].lower():
    errors.append(f"manifest hash {sha[:12]}… does not match the actual archive {os.environ['ORIG_HASH'][:12]}…")
counts = m.get("expectedCounts", {})
for k in ("files", "knowledge_objects"):
    if k not in counts: errors.append(f"expectedCounts must include {k}")
rep = m.get("representative", {})
if not ((rep.get("sourceVersionID") and rep.get("contentHash")) or rep.get("fileID")):
    errors.append("representative must supply sourceVersionID+contentHash or fileID")
if errors:
    for e in errors: print(f"::error::manifest invalid: {e}")
    sys.exit(1)
print(f"manifest OK — fixture {m['fixtureID']}, v{m['originalSchemaVersion']} → v{m['expectedEndVersion']}")
PY

# ── 2. Disposable working copy (never touch the original) ──────────────────────────────────────
WORKDIR="$(mktemp -d -t kals-real-archive)"
trap 'rm -rf "$WORKDIR"' EXIT
WORK="$WORKDIR/archive.sqlite"
cp "$ARCHIVE" "$WORK"
for side in wal shm; do [ -f "${ARCHIVE}-${side}" ] && cp "${ARCHIVE}-${side}" "${WORK}-${side}"; done
WORK_HASH_BEFORE="$(shasum -a 256 "$WORK" | awk '{print $1}')"
[ "$WORK_HASH_BEFORE" = "$ORIG_HASH_BEFORE" ] || { echo "::error::working copy != original before migration"; exit 1; }
REPORT="$WORKDIR/acceptance-report.json"

# ── 3. Run the REAL migration path via the external-archive Xcode test ─────────────────────────
# TEST_RUNNER_-prefixed vars are forwarded (prefix-stripped) into the test process ONLY when they
# are ENVIRONMENT variables of xcodebuild — passing them as trailing KEY=VALUE args would make
# them build settings, which never reach the test runner. Same labelled runner-OS
# deployment-target compatibility override as the CI jobs.
DEPLOY="$(sw_vers -productVersion | cut -d. -f1-2)"
MANIFEST_ABS="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
echo "running OwnerArchiveMigrationAcceptanceTests on the working copy (macOS $(sw_vers -productVersion))…"
TEST_RUNNER_KALS_OWNER_ARCHIVE="$WORK" \
TEST_RUNNER_KALS_OWNER_ARCHIVE_MANIFEST="$MANIFEST_ABS" \
TEST_RUNNER_KALS_OWNER_ARCHIVE_REPORT="$REPORT" \
xcodebuild \
  -project Kalsmritikosh.xcodeproj \
  -scheme Kalsmritikosh \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/owner-archive/DerivedData \
  -resultBundlePath "$WORKDIR/Results.xcresult" \
  -skipMacroValidation \
  MACOSX_DEPLOYMENT_TARGET="$DEPLOY" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KalsmritikoshTests/OwnerArchiveMigrationAcceptanceTests \
  -parallel-testing-enabled NO \
  test 2>&1 | tee "$WORKDIR/test.log" | tail -5

# ── 4. Prove the test actually EXECUTED and passed (from the .xcresult, never console text) ────
SUMMARY="$(xcrun xcresulttool get test-results summary --path "$WORKDIR/Results.xcresult" --format json)"
SUMMARY_JSON="$SUMMARY" python3 - <<'PY'
import json, os, sys
d = json.loads(os.environ["SUMMARY_JSON"])
passed, failed, result = int(d.get("passedTests", 0)), int(d.get("failedTests", 0)), d.get("result")
skipped = int(d.get("skippedTests", 0))
print(f"acceptance xcresult: passed={passed} failed={failed} skipped={skipped} result={result}")
if passed < 1:
    print("::error::the acceptance test did not EXECUTE (skipped?) — env vars not forwarded?")
    sys.exit(1)
if failed > 0 or result != "Passed":
    print("::error::the acceptance test failed")
    sys.exit(1)
PY

# ── 5. The ORIGINAL must be untouched ──────────────────────────────────────────────────────────
ORIG_HASH_AFTER="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[ "$ORIG_HASH_AFTER" = "$ORIG_HASH_BEFORE" ] || { echo "::error::ORIGINAL archive was modified"; exit 1; }

# ── 6. Surface + retain the non-sensitive acceptance report ───────────────────────────────────
[ -f "$REPORT" ] || { echo "::error::acceptance report was not written"; exit 1; }
FIXTURE_ID="$(MANIFEST="$MANIFEST" python3 -c "import json,os;print(json.load(open(os.environ['MANIFEST']))['fixtureID'])" 2>/dev/null || echo real-archive)"
FINAL_REPORT="ci/migrations/fixtures/${FIXTURE_ID}-acceptance-report.json"
cp "$REPORT" "$FINAL_REPORT"
echo "── acceptance report ($FINAL_REPORT) ──"
cat "$FINAL_REPORT"
echo
echo "verify-real-archive: PASS — original untouched (sha256 $ORIG_HASH_BEFORE); working copy migrated + verified."
