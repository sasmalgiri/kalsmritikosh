#!/usr/bin/env bash
# Release-configuration guard (GOV-004 + GOV-001 locked contract — macro B).
# The shipping product promise is: macOS 15.6 floor with runtime-gated
# Foundation Models (GOV-004), fully offline release, no Ollama/cloud metadata
# in the release product (GOV-001). This guard proves it from the project file
# on every CI run so the configuration can never drift.
#
#   1. Deployment floor — every MACOSX_DEPLOYMENT_TARGET in the project must
#      be exactly 15.6. A stray value at ANY level (e.g. the old 26.5
#      test-target pin) silently overrides what a target resolves to and
#      breaks either the shipping floor or test execution.
#   2. Offline release — the app target's Release configuration must have
#      outgoing AND incoming network connections disabled, with App Sandbox
#      and Hardened Runtime enabled.
#   3. Honest metadata — the Release configuration must not carry the Ollama
#      local-network usage description (the Ollama path is DEBUG/internal
#      only), and the shipped Info.plist / privacy manifest must not mention
#      Ollama or its port.
set -uo pipefail
PBX="Kalsmritikosh.xcodeproj/project.pbxproj"
FAIL=0

if [ ! -f "$PBX" ]; then
  echo "::error::Release-configuration guard: $PBX not found (run from repo root)"
  exit 1
fi

# ── 1. Deployment-target floor ──────────────────────────────────────────────
FOUND_TARGETS=$(grep -oE "MACOSX_DEPLOYMENT_TARGET = [0-9.]+" "$PBX" | awk '{print $3}' | sort -u | tr '\n' ' ' | sed 's/ $//')
if [ -z "$FOUND_TARGETS" ]; then
  echo "::error::Release-configuration guard: no MACOSX_DEPLOYMENT_TARGET set anywhere in $PBX — the locked macOS 15.6 floor (GOV-004) is not pinned"
  FAIL=1
elif [ "$FOUND_TARGETS" != "15.6" ]; then
  echo "::error::Release-configuration guard: MACOSX_DEPLOYMENT_TARGET drift — locked shipping floor is 15.6 (GOV-004), project contains: $FOUND_TARGETS"
  grep -n "MACOSX_DEPLOYMENT_TARGET" "$PBX"
  FAIL=1
fi

# ── 2 + 3. App-target Release build configuration ──────────────────────────
# The app target's Release block is the only Debug/Release XCBuildConfiguration
# that carries ENABLE_APP_SANDBOX (project- and test-target blocks do not), so
# it can be located without hard-coding an object ID.
RELEASE_BLOCK=$(awk '
  /^\t\t[A-F0-9]+ \/\* (Debug|Release) \*\/ = \{$/ { inblk=1; buf="" }
  inblk { buf = buf $0 "\n" }
  inblk && /^\t\t\};$/ {
    if (buf ~ /ENABLE_APP_SANDBOX/ && buf ~ /name = Release;/) print buf
    inblk=0
  }' "$PBX")

if [ -z "$RELEASE_BLOCK" ]; then
  echo "::error::Release-configuration guard: could not locate the app target Release configuration (block with ENABLE_APP_SANDBOX + name = Release) in $PBX"
  FAIL=1
else
  require_setting() {
    local setting="$1"
    # NINTH AUDIT — no `printf | grep -q` here: under `pipefail`, grep -q
    # exiting early sends printf a SIGPIPE and the guard flakes with
    # "write error: Broken pipe". Pure shell matching has no pipe at all.
    case "$RELEASE_BLOCK" in
      *"$setting"*) : ;;
      *)
        echo "::error::Release-configuration guard: app target Release must contain '$setting'"
        FAIL=1 ;;
    esac
  }
  require_setting "ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO;"
  require_setting "ENABLE_INCOMING_NETWORK_CONNECTIONS = NO;"
  require_setting "ENABLE_APP_SANDBOX = YES;"
  require_setting "ENABLE_HARDENED_RUNTIME = YES;"

  FORBIDDEN=$(printf '%s' "$RELEASE_BLOCK" | grep -niE "ollama|11434|NSLocalNetworkUsageDescription" || true)
  if [ -n "$FORBIDDEN" ]; then
    echo "::error::Release-configuration guard: app target Release carries Ollama/local-network metadata (DEBUG/internal only):"
    echo "$FORBIDDEN"
    FAIL=1
  fi
fi

# ── 3b. Shipped plists must not mention Ollama or its port ─────────────────
PLIST_HITS=$(grep -niE "ollama|11434" Kalsmritikosh/Info.plist Kalsmritikosh/PrivacyInfo.xcprivacy 2>/dev/null || true)
if [ -n "$PLIST_HITS" ]; then
  echo "::error::Release-configuration guard: shipped plist mentions Ollama/its port:"
  echo "$PLIST_HITS"
  FAIL=1
fi

# ── 3c. Tracked entitlements must not grant network access ─────────────────
# (Sixteenth review.) The active build settings govern the product, but a
# tracked entitlements file granting network.client/server is a future-signing
# risk: anything that ever signs against the file directly would ship egress.
ENT_FILES=$(git ls-files "*.entitlements" 2>/dev/null || find . -name "*.entitlements" -not -path "./.git/*")
for ent in $ENT_FILES; do
  [ -f "$ent" ] || continue
  NET=$(python3 - "$ent" <<'PYENT'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
bad = [k for k in ("com.apple.security.network.client",
                   "com.apple.security.network.server") if d.get(k) is True]
print(" ".join(bad))
PYENT
)
  if [ -n "$NET" ]; then
    echo "::error::Release-configuration guard: tracked entitlements file '$ent' grants network access ($NET) — the product contract is zero network; set it to false"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "Release-configuration guard clean (floor 15.6, offline Release, no Ollama release metadata, no network entitlements)."
