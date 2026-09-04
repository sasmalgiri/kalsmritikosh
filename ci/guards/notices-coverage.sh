#!/usr/bin/env bash
# RC-4 guard: the shipped third-party notices must cover every bundled model
# artifact (by name from the compiled-hash manifest) and the tokenizer asset,
# in BOTH the repo notices and the in-app bundled copy. A new model can never
# ship unattributed.
set -uo pipefail
REPO_NOTICES="THIRD_PARTY_NOTICES.md"
APP_NOTICES="Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt"
HASHES="release/COMPILED_MODEL_HASHES.json"
FAIL=0

for f in "$REPO_NOTICES" "$APP_NOTICES" "$HASHES"; do
  if [ ! -f "$f" ]; then echo "::error::Notices guard: $f not found"; FAIL=1; fi
done
[ "$FAIL" -ne 0 ] && exit 1

# Every model named in the hash manifest must appear in both notices.
MODELS=$(grep -oE '"[A-Za-z0-9_]+\.mlmodelc' "$HASHES" | tr -d '"' | sed 's/\.mlmodelc//' | sort -u)
if [ -z "$MODELS" ]; then
  echo "::error::Notices guard: no model names found in $HASHES (manifest shape changed?)"
  exit 1
fi
for m in $MODELS; do
  # Match on the family stem (BGESmallEmbedder → BGE), since notices name the
  # upstream model, not the compiled artifact.
  stem=$(echo "$m" | grep -oE '^[A-Z]{2,}' | sed 's/.$//')
  [ -z "$stem" ] && stem="$m"
  for f in "$REPO_NOTICES" "$APP_NOTICES"; do
    if ! grep -qi "$stem" "$f"; then
      echo "::error::Notices guard: bundled model '$m' (stem '$stem') is not attributed in $f"
      FAIL=1
    fi
  done
done

# The tokenizer/vocab asset ships too — it must be attributed (the BGE
# tokenizer vocabulary rides with the models; either word satisfies).
if ! grep -qiE "tokenizer|vocab" "$REPO_NOTICES"; then
  echo "::error::Notices guard: tokenizer/vocab asset not attributed in $REPO_NOTICES"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "Notices coverage: every bundled model + tokenizer attributed in repo and app copies."
