#!/usr/bin/env bash
# A2 — the AI Included relay host is written twice: in the app (AIIncludedRelay.host, which builds the
# request) and in the network helper (NetworkService.relayHost, its allowlist). They must be identical,
# or a deployed relay is either refused by the helper or allowed without the app offering it.
# Also runs the relay's own tests when a Node that runs TypeScript directly (≥ 23.6) is present.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
app=$(grep -E 'public static let host = "' "$ROOT/Kalsmritikosh/Routing/Providers/Online/AIIncludedRelay.swift" | sed -E 's/.*"(.*)".*/\1/')
helper=$(grep -E 'static let relayHost = "' "$ROOT/KalsmritikoshNetworkHelper/KalsmritikoshNetworkHelper.swift" | sed -E 's/.*"(.*)".*/\1/')
if [ "$app" != "$helper" ]; then
  echo "FAIL: AIIncludedRelay.host ('$app') != NetworkService.relayHost ('$helper')"
  exit 1
fi
echo "ok: relay host identical in app and helper ('${app:-not configured}')"
if command -v node >/dev/null 2>&1; then
  major=$(node -p 'process.versions.node.split(".")[0]'); minor=$(node -p 'process.versions.node.split(".")[1]')
  if [ "$major" -gt 23 ] || { [ "$major" -eq 23 ] && [ "$minor" -ge 6 ]; }; then
    (cd "$ROOT/relay" && node --test test/*.test.ts >/tmp/relay-tests.$$ 2>&1) || { cat /tmp/relay-tests.$$; rm -f /tmp/relay-tests.$$; echo "FAIL: relay tests"; exit 1; }
    grep -E '^ℹ (pass|fail)' /tmp/relay-tests.$$; rm -f /tmp/relay-tests.$$
  else
    echo "skip: relay tests need Node ≥ 23.6 (found $(node -v))"
  fi
fi
