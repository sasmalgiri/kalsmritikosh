#!/usr/bin/env bash
# No try! / fatalError( outside the UI layer. UI and comment-only lines are excluded.
set -uo pipefail
MATCHES=$(grep -rnE "try!|fatalError\(" Kalsmritikosh/ --include="*.swift" 2>/dev/null \
  | grep -vE "^Kalsmritikosh/UI/" \
  | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
if [ -n "$MATCHES" ]; then
  echo "::error::try! or fatalError() found in non-UI code"
  echo "$MATCHES"
  exit 1
fi
echo "No try! / fatalError() in non-UI code."
