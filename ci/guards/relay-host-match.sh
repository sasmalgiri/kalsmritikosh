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
# A3 — the blocked storefronts, in the app and in the relay.
appBlocked=$(sed -n '/static let blocked/,/\]/p' "$ROOT/Kalsmritikosh/App/Store/AIRegion.swift" | grep -oE '"[A-Z]{3}"' | tr -d '"' | sort | tr '\n' ' ')
relayBlocked=$(grep -E 'AI_BLOCKED_STOREFRONTS' "$ROOT/relay/src/policy.ts" | grep -oE '"[A-Z]{3}"' | tr -d '"' | sort | tr '\n' ' ')
if [ -z "$appBlocked" ] || [ "$appBlocked" != "$relayBlocked" ]; then
  echo "FAIL: AIRegion.blocked ($appBlocked) != AI_BLOCKED_STOREFRONTS ($relayBlocked)"
  exit 1
fi
echo "ok: AI-blocked storefronts identical in app and relay ($appBlocked)"
# A8–A10 — the public-record hosts, in the app (PublicSource.host) and the helper (lookupHosts).
appLookup=$(sed -n '/public var host: String {/,/^    }/p' "$ROOT/Kalsmritikosh/Routing/Providers/Online/PublicLookups.swift" | grep -oE '"[a-z0-9.-]+"' | tr -d '"' | sort -u | tr '\n' ' ')
helperLookup=$(sed -n '/static let lookupHosts/,/\]/p' "$ROOT/KalsmritikoshNetworkHelper/KalsmritikoshNetworkHelper.swift" | grep -oE '"[a-z0-9.-]+"' | tr -d '"' | sort -u | tr '\n' ' ')
if [ -z "$appLookup" ] || [ "$appLookup" != "$helperLookup" ]; then
  echo "FAIL: PublicSource hosts ($appLookup) != helper lookupHosts ($helperLookup)"
  exit 1
fi
echo "ok: public-record hosts identical in app and helper ($appLookup)"
if command -v node >/dev/null 2>&1; then
  major=$(node -p 'process.versions.node.split(".")[0]'); minor=$(node -p 'process.versions.node.split(".")[1]')
  if [ "$major" -gt 23 ] || { [ "$major" -eq 23 ] && [ "$minor" -ge 6 ]; }; then
    (cd "$ROOT/relay" && node --test test/*.test.ts >/tmp/relay-tests.$$ 2>&1) || { cat /tmp/relay-tests.$$; rm -f /tmp/relay-tests.$$; echo "FAIL: relay tests"; exit 1; }
    grep -E '^ℹ (pass|fail)' /tmp/relay-tests.$$; rm -f /tmp/relay-tests.$$
  else
    echo "skip: relay tests need Node ≥ 23.6 (found $(node -v))"
  fi
fi
