#!/bin/bash
# ALCOA ALC-08 (owner 2026-11-24) — "fair-eval": no release while a pinned model has no recorded fair evaluation.
#
# 1. The pinned models agree: the relay's model (relay/src/policy.ts DEFAULT_ANTHROPIC_MODEL), the one the relay is deployed
#    with (relay/wrangler.toml ANTHROPIC_MODEL) and the one the app expects (AIPricing.relayModel) must be one id; the
#    own-key default (OnlineProviderKind.anthropic.defaultModel) is read too.
# 2. Each pinned model id has a recorded fair evaluation: a docs/evidence/agent-eval-*/FAIR*.md file with a line
#    `Model evaluated: <id>` (exact id), run by a live AI on that model with the fair protocol (blind reader, scored final
#    answers) — an agent-simulated reader does not count. Changing a pinned model therefore re-opens this gate until the
#    fair evaluation is re-run on the new model and recorded.
set -uo pipefail
cd "$(dirname "$0")/.."
relay=$(grep -E '^export const DEFAULT_ANTHROPIC_MODEL = "' relay/src/policy.ts | sed -E 's/.*"(.*)".*/\1/')
toml=$(grep -E '^ANTHROPIC_MODEL = "' relay/wrangler.toml | sed -E 's/^ANTHROPIC_MODEL = "([^"]*)".*/\1/')
app=$(grep -E 'static let relayModel = "' Kalsmritikosh/Routing/Providers/Online/AIPricing.swift | sed -E 's/.*"(.*)".*/\1/')
ownkey=$(grep -E 'case \.anthropic: return "claude-' Kalsmritikosh/Routing/Providers/Online/OnlineProviderKind.swift | head -1 | sed -E 's/.*"(.*)".*/\1/')
if [ -z "$relay" ] || [ "$relay" != "$toml" ] || [ "$relay" != "$app" ]; then
  echo "FAIL: pinned relay model differs: policy.ts ($relay), wrangler.toml ($toml), AIPricing.relayModel ($app)"
  exit 1
fi
if [ -z "$ownkey" ]; then echo "FAIL: the own-key default model could not be read"; exit 1; fi
missing=""
for m in $(printf '%s\n%s\n' "$relay" "$ownkey" | sort -u); do
  found=$(grep -lE "^Model evaluated: \`?$m\`?\s*$" docs/evidence/agent-eval-*/FAIR*.md 2>/dev/null | head -1)
  if [ -z "$found" ]; then missing="$missing $m"; else echo "ok: $m — fair evaluation recorded in $found"; fi
done
if [ -n "$missing" ]; then
  echo "OPEN: no recorded fair evaluation (a FAIR*.md with 'Model evaluated: <id>') for:$missing"
  exit 1
fi
echo "ok: every pinned model ($relay, $ownkey) has a recorded fair evaluation"
