#!/bin/bash
#
# check-claims.sh — PHASE E, rebuilt on explicit IDs (tenth audit).
# The AUTHORITY is the data-claim id gate, checked in BOTH directions:
#   registry → site: every row's id appears in a data-claim attribute, its
#                    verbatim fragment still exists, and its proof is alive;
#   site → registry: every data-claim id found in the HTML has exactly one row.
# A keyword heuristic remains as a SECONDARY WARNING for likely enforcement
# copy shipped without a tag. Refused vocabulary always fails.
#
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# All data-claim ids used on the site (attributes may carry several,
# space-separated).
SITE_IDS=$(grep -rhoE 'data-claim="[^"]*"' docs --include="*.html" \
  | sed -e 's/^data-claim="//' -e 's/"$//' | tr ' ' '\n' | sed '/^$/d' | sort)
SITE_IDS_UNIQUE=$(printf '%s\n' "$SITE_IDS" | sort -u)

# Registry rows: | `id` | `fragment` | proof |
REGISTRY_ROWS=$(grep '^| `' CLAIMS.md)
REGISTRY_IDS=$(printf '%s\n' "$REGISTRY_ROWS" \
  | sed -E 's/^\| `([^`]+)`.*$/\1/' | sort)

# 1 — registry ids are unique (exactly one row per id).
DUP_IDS=$(printf '%s\n' "$REGISTRY_IDS" | uniq -d)
if [ -n "$DUP_IDS" ]; then
  echo "::error::CLAIMS.md — duplicate claim id row(s):"; echo "$DUP_IDS"; fail=1
fi

# 2 — per registry row: id on site + fragment on site + proof alive.
while IFS='|' read -r _ id claim proof _; do
  id="$(echo "$id" | sed -e 's/^[[:space:]]*`//' -e 's/`[[:space:]]*$//')"
  claim="$(echo "$claim" | sed -e 's/^[[:space:]]*`//' -e 's/`[[:space:]]*$//')"
  proof="$(echo "$proof" | xargs)"
  [ -z "$id" ] && continue
  grep -Fxq "$id" <<< "$SITE_IDS_UNIQUE" \
    || { echo "::error::CLAIMS.md — id '$id' has no data-claim attribute on the site"; fail=1; }
  grep -rqF "$claim" docs --include="*.html" \
    || { echo "::error::CLAIMS.md — registered claim '$id' no longer on the site: $claim (update the registry with the copy)"; fail=1; }
  case "$proof" in
    test:*)
      sym="${proof#test:}"
      grep -rq "func $sym" KalsmritikoshTests || { echo "::error::CLAIMS.md — proof test '$sym' not found (claim: $id)"; fail=1; } ;;
    ci:*)
      frag="${proof#ci:}"
      grep -rqF "$frag" .github/workflows || { echo "::error::CLAIMS.md — proof CI fragment '$frag' not found (claim: $id)"; fail=1; } ;;
    grep:*)
      body="${proof#grep:}"; pattern="${body%%:*}"; path="${body#*:}"
      grep -rq "$pattern" "$path" || { echo "::error::CLAIMS.md — proof pattern '$pattern' not in $path (claim: $id)"; fail=1; } ;;
    owner:*)
      # An owner: proof is CONDITIONAL — the named file must be a real,
      # living checklist (eighth audit: existence alone proved nothing).
      f="${proof#owner:}"
      if [ ! -f "$f" ]; then
        echo "::error::CLAIMS.md — owner file '$f' missing (claim: $id)"; fail=1
      elif ! grep -qE '\- \[[ x]\]' "$f"; then
        echo "::error::CLAIMS.md — owner file '$f' carries no checklist items (claim: $id)"; fail=1
      else
        echo "check-claims note: '$id' is owner-conditional — true only once the acts in $f are checked off"
      fi ;;
    *) echo "::error::CLAIMS.md — row '$id' has no recognized proof kind: $proof"; fail=1 ;;
  esac
done < <(printf '%s\n' "$REGISTRY_ROWS")

# 3 — site → registry: every data-claim id on the site has a registry row.
while IFS= read -r sid; do
  [ -z "$sid" ] && continue
  grep -Fxq "$sid" <<< "$REGISTRY_IDS" \
    || { echo "::error::site data-claim id '$sid' has no CLAIMS.md row"; fail=1; }
done <<< "$SITE_IDS_UNIQUE"

# 4 — refused vocabulary must never ship.
for phrase in "provable compliance" "provably compliant" "legally compliant" "guarantees compliance" "court-admissible"; do
  if grep -rilF "$phrase" docs --include="*.html" | grep -q .; then
    echo "::error::REFUSED claim vocabulary on the site: '$phrase'"; fail=1
  fi
done

# 5 — SECONDARY WARNING (the id gate above is the authority): lines that
# smell like enforcement copy but carry neither a data-claim attribute nor a
# claims-exempt marker. Warns, never fails — per the tenth audit.
while IFS=: read -r file line text; do
  case "$text" in *claims-exempt*|*data-claim=*) continue ;; esac
  echo "::warning::possible untagged enforcement claim at $file:$line — tag the element data-claim=\"<id>\" and add a CLAIMS.md row, or mark it claims-exempt"
done < <(grep -rinE "enforce|refuses|refuse to|guarantee|tamper-proof|cannot be edited|cryptographically|blocked until|always blocked" docs --include="*.html")

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-claims: id gate clean in both directions; every proof alive; refused vocabulary absent."
