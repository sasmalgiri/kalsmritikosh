#!/usr/bin/env bash
# Privacy invariant: network may live ONLY in Routing/ and Ingestion/ASR/ (the optional,
# release-gated cloud transcriber). Brain / Knowledge / Retrieval / Storage / Experts / Export /
# UI / Core must never touch the network. Comment-only lines excluded.
set -uo pipefail
MATCHES=$(grep -rnE "URLSession|URLRequest|\.dataTask" Kalsmritikosh/ --include="*.swift" 2>/dev/null \
  | grep -vE "^Kalsmritikosh/Routing/" \
  | grep -vE "^Kalsmritikosh/Ingestion/ASR/" \
  | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
if [ -n "$MATCHES" ]; then
  echo "::error::Network call found in an evidence/answer layer — privacy contract violation"
  echo "$MATCHES"
  exit 1
fi
echo "No network calls in the evidence/answer layers."
