#!/usr/bin/env bash
# Capability discipline: NO model names in the evidence/answer layers. Model names live ONLY in
# Routing/Providers, ModelManifest, AppState, SettingsView. Comment-only lines are allowed
# (docstrings may reference a model for context); a real code leak is still caught.
set -uo pipefail
MATCHES=$(grep -rniE "qwen|gemma|deepseek|llama|mistral|nomic|gpt" \
  Kalsmritikosh/Experts/ \
  Kalsmritikosh/Brain/ \
  Kalsmritikosh/Knowledge/ \
  Kalsmritikosh/Retrieval/ \
  Kalsmritikosh/Ingestion/ \
  2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
if [ -n "$MATCHES" ]; then
  echo "::error::Capability-discipline guard failed — model names leaked into evidence/answer layers"
  echo "$MATCHES"
  exit 1
fi
echo "Capability-discipline guard clean."
