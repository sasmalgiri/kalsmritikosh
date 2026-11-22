#!/usr/bin/env bash
# Unified path R2-E — SIMULATED release candidate (SHIP-01, SHIP-02, SHIP-11, SHIP-12, QA-13).
# Freezes the candidate (full SHA, clean tree, schema, version, toolchain, dependency pins, Release build settings),
# builds a Release app into a temporary DerivedData with AD-HOC signing (not Distribution), hashes the artifact,
# checks the signature, entitlements, the embedded SQLCipher and the extensions, copies the app OUTSIDE every build
# folder and launches it there, then writes the evidence packet and a scope verdict computed from the checks.
# A Distribution-signed archive, notarisation / App Store processing and a clean second Mac are still needed.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/release-candidate.md"
sim_banner "$R" "release candidate packet (ad-hoc signed, not Distribution)"
checks=()   # "name|PASS/FAIL|detail"
add() { checks+=("$1|$2|$3"); }

SHA="$(git rev-parse HEAD)"
if [ -z "$(git status --porcelain -- Kalsmritikosh KalsmritikoshTests KalsmritikoshNetworkHelper KalsmritikoshShare relay | grep -v xcstrings || true)" ]; then
  add "clean source tree" PASS "$SHA"; else add "clean source tree" FAIL "uncommitted source changes: the candidate is not frozen"; fi
SCHEMA="$(grep -Eo 'latestVersion = [0-9]+' Kalsmritikosh/Storage/Schema/SchemaMigrations.swift | grep -Eo '[0-9]+')"
{
  echo "## Candidate"
  echo "- Commit: \`$SHA\`"
  echo "- Schema: v$SCHEMA"
  echo "- Toolchain: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "- macOS: $(sw_vers -productVersion)"
  echo
  echo "## Dependency pins"
  find . -name Package.resolved -not -path "*/DerivedData/*" -not -path "./build/*" 2>/dev/null | head -3 | while read -r f; do
    python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for p in d.get("pins", d.get("object", {}).get("pins", [])):
    s=p.get("state",{}); print("- %s %s (%s)" % (p.get("identity", p.get("package")), s.get("version") or "", (s.get("revision") or "")[:12]))
PY
  done
  echo
  echo "## Release build settings (selected)"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | grep -E '^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER|MACOSX_DEPLOYMENT_TARGET|SWIFT_VERSION|ENABLE_HARDENED_RUNTIME|CODE_SIGN_ENTITLEMENTS|SWIFT_OPTIMIZATION_LEVEL) =' \
    | sort -u | sed 's/^ */- /'
  echo
} >> "$R"

set +e
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$SIM_DERIVED" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  > "$SIM_DERIVED.release-build.log" 2>&1
rc=$?
set -e
APP="$(find "$SIM_DERIVED/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
if [ $rc -ne 0 ] || [ -z "$APP" ]; then
  add "Release build" FAIL "xcodebuild exit $rc (log tail below)"
  tail -20 "$SIM_DERIVED.release-build.log" | sed 's/^/    /' >> "$R"
else
  add "Release build" PASS "$(basename "$APP")"
  OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/kals-sim-install.XXXXXX")"
  ditto "$APP" "$OUTSIDE/$(basename "$APP")"
  INSTALLED="$OUTSIDE/$(basename "$APP")"
  echo "## Artifact hashes (SHA-256)" >> "$R"
  (cd "$INSTALLED/Contents" && find . -type f \( -path './MacOS/*' -o -name '*.dylib' -o -path './PlugIns/*/Contents/MacOS/*' -o -path './Extensions/*/Contents/MacOS/*' \) -print0 \
    | xargs -0 shasum -a 256 | sed 's/^/- /') >> "$R"
  echo >> "$R"
  if codesign --verify --deep --strict "$INSTALLED" 2>>"$R"; then add "signature (ad-hoc) verifies" PASS "codesign --verify --deep --strict"; else add "signature (ad-hoc) verifies" FAIL "see above"; fi
  ENT="$(codesign -d --entitlements :- "$INSTALLED" 2>/dev/null || true)"
  if echo "$ENT" | grep -q "com.apple.security.app-sandbox"; then add "sandbox entitlement present" PASS ""; else add "sandbox entitlement present" FAIL "no app-sandbox entitlement"; fi
  if echo "$ENT" | grep -q "com.apple.security.network.client"; then add "main app has no network.client" FAIL "network.client found on the main app"; else add "main app has no network.client" PASS "only the helper may connect"; fi
  BIN="$INSTALLED/Contents/MacOS/$(defaults read "$INSTALLED/Contents/Info" CFBundleExecutable 2>/dev/null || basename "$INSTALLED" .app)"
  if nm -gU "$BIN" 2>/dev/null | grep -q "sqlcipher_export\|_sqlite3_key" || otool -L "$BIN" | grep -qi sqlcipher \
     || find "$INSTALLED/Contents/Frameworks" -iname '*sqlcipher*' 2>/dev/null | grep -q .; then
    add "SQLCipher embedded" PASS "symbols or framework found in the artifact"; else add "SQLCipher embedded" FAIL "no SQLCipher symbols or framework"; fi
  if otool -L "$BIN" | grep -q "$SIM_DERIVED\|/DerivedData/"; then add "no build-folder load paths" FAIL "links into a build folder"; else add "no build-folder load paths" PASS ""; fi
  EXT="$(find "$INSTALLED/Contents" -name '*.appex' | wc -l | tr -d ' ')"
  if [ "$EXT" -ge 1 ]; then add "extensions embedded" PASS "$EXT .appex"; else add "extensions embedded" FAIL "no extensions"; fi
  open -n "$INSTALLED" --args -KalsSimulatedLaunch YES || true
  sleep 15
  if pgrep -f "$INSTALLED/Contents/MacOS" >/dev/null; then add "launches outside the build folder" PASS "running after 15 s"; else add "launches outside the build folder" FAIL "not running after 15 s"; fi
  pkill -f "$INSTALLED/Contents/MacOS" || true
  sleep 2
  rm -rf "$OUTSIDE"
fi

echo "## Checks" >> "$R"
echo "| Check | Result | Detail |" >> "$R"; echo "|---|---|---|" >> "$R"
fails=0
for c in "${checks[@]}"; do IFS='|' read -r n s d <<< "$c"; echo "| $n | $s (simulated) | $d |" >> "$R"; [ "$s" = FAIL ] && fails=$((fails+1)); done
{
  echo
  echo "## Scope verdict (SHIP-12, SIMULATED)"
  if [ $fails -eq 0 ]; then
    echo "SIMULATED candidate checks pass. NOT shippable on this evidence: no Distribution signature, no TestFlight/App Store processing, no clean second Mac, no human journeys, no deployed relay. Bind real evidence to commit \`$SHA\`; any later code change re-runs this packet."
  else
    echo "SIMULATED candidate has $fails failing check(s): not shippable."
  fi
  echo
  echo "## Still needed for release"
  echo "- Owner: Distribution archive and validation in Xcode Organizer; TestFlight upload; clean-Mac launch; the relay host."
} >> "$R"
sim_cleanup_derived
rm -f "$SIM_DERIVED.release-build.log"
echo "release-candidate: $R"
