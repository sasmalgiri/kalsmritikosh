#!/usr/bin/env bash
# PI.4: synthetic questions are a DEBUG-only diagnostic. The answer path (Brain/) must not
# reference the generator/queue. Comment-only lines excluded.
set -uo pipefail
MATCHES=$(grep -rnE "SyntheticQuestion(Generator|Queue)" Kalsmritikosh/Brain/ --include="*.swift" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
if [ -n "$MATCHES" ]; then
  echo "::error::Synthetic-question type referenced in the answer path (Brain/)"
  echo "$MATCHES"
  exit 1
fi
echo "No synthetic-question types in the answer path."
