#!/usr/bin/env bash
# W0-C — prove Private mode is offline FROM THE SIGNED APP (ported from mailin's
# Scripts/verify-no-network.sh). Under the App Sandbox a process with no network
# entitlement cannot open a socket, whatever its code asks for; this reads the
# entitlements actually signed into the build.
#
#   scripts/verify-no-network.sh /path/to/Kalsmritikosh.app
#   scripts/verify-no-network.sh                  # newest Release build in DerivedData
#
# Checks (non-zero exit on the first failure):
#   main app   — sandboxed; network.client NOT granted; network.server NOT granted
#   helper     — if Contents/XPCServices/KalsmritikoshNetwork.xpc exists (Online mode, O-2):
#                sandboxed; network.server NOT granted (network.client is its only job)
#   Info.plist — no NSAppTransportSecurity exceptions in either bundle
set -uo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
  APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/Kalsmritikosh-*/Build/Products/Release/Kalsmritikosh.app 2>/dev/null | head -1)
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "verify-no-network: no Kalsmritikosh.app found (pass the path, or build Release first)"; exit 2
fi

ent() { codesign -d --entitlements :- "$1" 2>/dev/null; }
has_true() { /usr/libexec/PlistBuddy -c "Print :$2" /dev/stdin <<<"$1" 2>/dev/null | grep -q "^true$"; }

check_bundle() {
  local bundle="$1" role="$2" allow_client="$3"
  local e; e=$(ent "$bundle")
  if [ -z "$e" ]; then echo "FAIL [$role] cannot read signed entitlements of $bundle"; exit 1; fi
  has_true "$e" "com.apple.security.app-sandbox" || { echo "FAIL [$role] not sandboxed"; exit 1; }
  if has_true "$e" "com.apple.security.network.server"; then echo "FAIL [$role] grants network.server"; exit 1; fi
  if [ "$allow_client" = "no" ] && has_true "$e" "com.apple.security.network.client"; then
    echo "FAIL [$role] grants network.client"; exit 1
  fi
  if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
    echo "FAIL [$role] declares NSAppTransportSecurity exceptions"; exit 1
  fi
  echo "ok   [$role] sandboxed, network.server absent$( [ "$allow_client" = "no" ] && echo ", network.client absent")"
}

check_bundle "$APP" "main app" "no"
HELPER="$APP/Contents/XPCServices/KalsmritikoshNetwork.xpc"
if [ -d "$HELPER" ]; then
  check_bundle "$HELPER" "network helper" "yes"
  echo "Online mode is available in this build; Private mode never launches the helper."
else
  echo "No network helper bundled: this build cannot reach the network at all."
fi
echo "verify-no-network: PASS ($APP)"
