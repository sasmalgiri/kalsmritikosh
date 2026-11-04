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
appBlocked=$(sed -n '/static let blocked/,/return list/p' "$ROOT/Kalsmritikosh/App/Store/AIRegion.swift" | grep -oE '"[A-Z]{3}"' | tr -d '"' | sort | tr '\n' ' ')
relayBlocked=$(grep -E 'AI_BLOCKED_STOREFRONTS' "$ROOT/relay/src/policy.ts" | grep -oE '"[A-Z]{3}"' | tr -d '"' | sort | tr '\n' ' ')
if [ -z "$appBlocked" ] || [ "$appBlocked" != "$relayBlocked" ]; then
  echo "FAIL: AIRegion.blocked ($appBlocked) != AI_BLOCKED_STOREFRONTS ($relayBlocked)"
  exit 1
fi
echo "ok: AI-blocked storefronts identical in app and relay ($appBlocked)"
# Plans and credits (2026-11-04) — the plan limits, pack sizes and Claude rates: relay/src/policy.ts is the
# authority, Kalsmritikosh/Routing/Providers/Online/AIPricing.swift mirrors them for display.
num() { tr -d '_ ' | grep -oE '[0-9.]+' | tr '\n' ' '; }
for tier in "ai:aiIncluded" "pro:aiPro"; do
  r=${tier%%:*}; a=${tier##*:}
  relayPlan=$(grep -E "^\s*$r:\s*\{ label" "$ROOT/relay/src/policy.ts" | sed -E 's/.*monthlyCredits/monthlyCredits/' | num)
  appPlan=$(grep -E "static let $a = PlanLimits" "$ROOT/Kalsmritikosh/Routing/Providers/Online/AIPricing.swift" | sed -E 's/.*monthlyCredits/monthlyCredits/' | num)
  if [ -z "$relayPlan" ] || [ "$relayPlan" != "$appPlan" ]; then
    echo "FAIL: plan '$r' limits differ: relay ($relayPlan) != app ($appPlan)"
    exit 1
  fi
done
relayRates=$(grep -E '"claude-opus-5": \{ inputPerMTok' "$ROOT/relay/src/policy.ts" | sed -E 's/.*inputPerMTok/inputPerMTok/' | num)
appRates=$(grep -E '"claude-opus-5": Rates\(inputPerMTok' "$ROOT/Kalsmritikosh/Routing/Providers/Online/AIPricing.swift" | sed -E 's/.*inputPerMTok/inputPerMTok/' | num)
if [ -z "$relayRates" ] || [ "$relayRates" != "$appRates" ]; then
  echo "FAIL: claude-opus-5 rates differ: relay ($relayRates) != app ($appRates)"
  exit 1
fi
echo "ok: plan limits and Claude rates identical in app and relay"
# The ONE size estimator (2026-11-04 simulation fix): the app sizes whole-case reads and its credit pre-check
# with the relay's constants, so a read the app offers is never refused too-large/too-costly by the relay.
for pair in "CHARS_PER_TOKEN:charsPerToken" "TOKEN_OVERHEAD:tokenOverhead" "IMAGE_TOKENS:imageTokens" \
            "MAX_OUTPUT_TOKENS:maxOutputTokens" "MAX_INPUT_CHARS:maxInputChars" "LARGE_READ_MAX_INPUT_CHARS:largeReadMaxInputChars"; do
  r=${pair%%:*}; a=${pair##*:}
  relayVal=$(grep -E "^export const $r(: [A-Za-z]+)? = " "$ROOT/relay/src/policy.ts" | sed -E 's/.*= *([0-9_]+).*/\1/' | tr -d '_')
  appVal=$(grep -E "public static let $a = " "$ROOT/Kalsmritikosh/Routing/Providers/Online/AIPricing.swift" | sed -E 's/.*= *([0-9_]+).*/\1/' | tr -d '_')
  if [ -z "$relayVal" ] || [ "$relayVal" != "$appVal" ]; then
    echo "FAIL: estimator constant $r ($relayVal) != AIPricing.$a ($appVal)"
    exit 1
  fi
done
echo "ok: size estimator constants identical in app and relay"
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
