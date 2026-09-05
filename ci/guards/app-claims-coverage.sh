#!/usr/bin/env bash
# RC-7 / P5-U1 — the claims gate's in-app + ASC legs. Every row in
# CLAIMS_APP.md must find its verbatim fragment in its named source file.
# One discipline, three surfaces (the site leg lives in scripts/check-claims.sh).
set -uo pipefail
FAIL=0
while IFS='|' read -r _ id fragment source _; do
  id=$(echo "$id" | xargs)
  fragment=$(echo "$fragment" | sed -e 's/^[[:space:]]*`//' -e 's/`[[:space:]]*$//')
  source=$(echo "$source" | xargs)
  [ -z "$id" ] || [ "$id" = "Claim ID" ] || [[ "$id" == :* ]] || [[ "$id" == -* ]] && continue
  if [ ! -f "$source" ]; then
    echo "::error::App-claims guard: $id names a missing source: $source"; FAIL=1; continue
  fi
  if ! grep -qF "$fragment" "$source"; then
    echo "::error::App-claims guard: $id — fragment not found in $source: \"$fragment\" (copy and registry move together)"
    FAIL=1
  fi
done < <(grep -E '^\| (app|asc)\.' CLAIMS_APP.md)
if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "App/ASC claims coverage: every registered fragment lives in its source."
