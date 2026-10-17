#!/usr/bin/env bash
# X-4 — the Safari clipper never makes a network request. Its scripts only serialise the page
# the browser already shows and hand it to the native handler; its manifest asks for no host
# access and no request APIs; its native code opens no connection.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/KalsmritikoshClipper"
rc=0
[ -d "$DIR" ] || { echo "::error::KalsmritikoshClipper folder missing"; exit 1; }
if grep -nE '\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts)\b' "$DIR"/*.js; then
  echo "::error::clipper JavaScript uses a network API"; rc=1
fi
if grep -nE 'https?://' "$DIR"/*.js "$DIR"/*.html; then
  echo "::error::clipper script or page references a remote address"; rc=1
fi
if grep -nE '"(host_permissions|webRequest|webRequestBlocking|declarativeNetRequest|cookies|<all_urls>)"' "$DIR/manifest.json"; then
  echo "::error::clipper manifest asks for host or request permissions"; rc=1
fi
if grep -nE '\b(URLSession|NWConnection|CFNetwork|URLRequest|Network\b)' "$DIR"/*.swift; then
  echo "::error::clipper native code opens a connection"; rc=1
fi
for k in ENABLE_OUTGOING_NETWORK_CONNECTIONS ENABLE_INCOMING_NETWORK_CONNECTIONS; do
  if ! awk '/KalsmritikoshClipper\/KalsmritikoshClipper.entitlements/{f=1} f&&/'"$k"' = NO;/{print; f=0}' "$ROOT/Kalsmritikosh.xcodeproj/project.pbxproj" | grep -q .; then
    echo "::error::clipper target does not set $k = NO"; rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "Clipper guard clean (no network API, no remote address, no host permissions, network off)."
exit $rc
