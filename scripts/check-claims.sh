#!/bin/bash
#
# check-claims.sh — PHASE E: the claims registry gate.
# Every registered public claim must still appear on the site, its proof must
# still exist, and the refused vocabulary must not appear anywhere in docs/.
#
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 1 — every registered claim's copy still exists, and its proof is alive.
while IFS='|' read -r _ claim proof _; do
  claim="$(echo "$claim" | sed -e 's/^[[:space:]]*`//' -e 's/`[[:space:]]*$//')"
  proof="$(echo "$proof" | xargs)"
  [ -z "$claim" ] && continue
  case "$proof" in
    test:*)
      sym="${proof#test:}"
      grep -rq "func $sym" KalsmritikoshTests || { echo "::error::CLAIMS.md — proof test '$sym' not found (claim: $claim)"; fail=1; } ;;
    ci:*)
      frag="${proof#ci:}"
      grep -rqF "$frag" .github/workflows || { echo "::error::CLAIMS.md — proof CI fragment '$frag' not found (claim: $claim)"; fail=1; } ;;
    grep:*)
      body="${proof#grep:}"; pattern="${body%%:*}"; path="${body#*:}"
      grep -rq "$pattern" "$path" || { echo "::error::CLAIMS.md — proof pattern '$pattern' not in $path (claim: $claim)"; fail=1; } ;;
    owner:*)
      # An owner: proof is CONDITIONAL — the named file must be a real,
      # living checklist (eighth audit: existence alone proved nothing).
      f="${proof#owner:}"
      if [ ! -f "$f" ]; then
        echo "::error::CLAIMS.md — owner file '$f' missing (claim: $claim)"; fail=1
      elif ! grep -qE '\- \[[ x]\]' "$f"; then
        echo "::error::CLAIMS.md — owner file '$f' carries no checklist items (claim: $claim)"; fail=1
      else
        echo "check-claims note: '$claim' is owner-conditional — true only once the acts in $f are checked off"
      fi ;;
    *) continue ;;
  esac
  grep -rqF "$claim" docs --include="*.html" \
    || { echo "::error::CLAIMS.md — registered claim no longer on the site: $claim (update the registry with the copy)"; fail=1; }
done < <(grep '^| `' CLAIMS.md)

# 2 — refused vocabulary must never ship.
for phrase in "provable compliance" "provably compliant" "legally compliant" "guarantees compliance" "court-admissible"; do
  if grep -rilF "$phrase" docs --include="*.html" | grep -q .; then
    echo "::error::REFUSED claim vocabulary on the site: '$phrase'"; fail=1
  fi
done

# 3 — REVERSE direction (ninth audit): any site line that ASSERTS enforcement
# must carry a registered claim fragment, or an explicit `claims-exempt`
# marker (for disclaimers). This is a keyword heuristic, stated as such in
# CLAIMS.md — it catches new enforcement copy shipped without a proof row.
CLAIMS_FRAGMENTS=$(grep '^| `' CLAIMS.md | sed -e 's/^| `//' -e 's/`.*$//')
while IFS=: read -r file line text; do
  case "$text" in *claims-exempt*) continue ;; esac
  covered=0
  while IFS= read -r frag; do
    [ -z "$frag" ] && continue
    case "$text" in *"$frag"*) covered=1; break ;; esac
  done <<< "$CLAIMS_FRAGMENTS"
  if [ "$covered" -eq 0 ]; then
    echo "::error::UNREGISTERED enforcement claim at $file:$line — add a CLAIMS.md row (with a living proof) or mark the line claims-exempt"
    echo "  $text"
    fail=1
  fi
done < <(grep -rinE "enforce|refuses|refuse to|guarantee|tamper-proof|cannot be edited|cryptographically" docs --include="*.html")

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-claims: every registered claim is on the site with a living proof; refused vocabulary absent."
