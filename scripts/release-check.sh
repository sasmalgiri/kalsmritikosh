#!/bin/bash
#
# release-check.sh — the release-gate command (App Store completion instructions 2026-10-30 §1.7).
#
# Reads ci/release-gates.json and reports every gate as PASS, FAIL or OPEN:
#   command  — runs the command; exit 0 is PASS, anything else FAIL.
#   evidence — the named file must exist, contain no placeholder ("[owner:", "TODO", "TBD"),
#              and name the candidate commit (--candidate <sha>, default: HEAD).
#   human    — a retained approval record release/approvals/<id>.md must exist with the fields
#              Decision, By, Role, Date and Commit, the Commit naming the candidate. The check
#              never writes one: a human decision is linked to its record, not generated.
# Missing evidence is OPEN. A required skip is not a pass. Exit 1 unless every required gate is PASS.
#
set -uo pipefail
cd "$(dirname "$0")/.."

CANDIDATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) CANDIDATE="$2"; shift 2 ;;
    *) echo "usage: $0 [--candidate <sha>]"; exit 2 ;;
  esac
done
[ -z "$CANDIDATE" ] && CANDIDATE="$(git rev-parse HEAD)"
SHORT="${CANDIDATE:0:8}"

command -v python3 >/dev/null || { echo "python3 is required"; exit 2; }

# bash 3 (macOS) has no mapfile: read the manifest into a temp file, one gate per line.
GATEFILE=$(mktemp -t release-gates)
trap 'rm -f "$GATEFILE"' EXIT
python3 - > "$GATEFILE" <<'PY'
import json
for g in json.load(open("ci/release-gates.json"))["gates"]:
    # a non-whitespace separator: `read` with a tab IFS would collapse empty fields
    print("\x1f".join([g["id"], g["kind"], str(g.get("required", True)).lower(), g.get("run", ""), g.get("evidence", ""), g["title"]]))
PY

pass=0; fail=0; open=0
printf '%-36s %-8s %-6s %s\n' "GATE" "RESULT" "REQ" "DETAIL"
printf '%-36s %-8s %-6s %s\n' "----" "------" "---" "------"

check_placeholders() {  # $1 file → 0 clean, 1 placeholder found
  grep -qE '\[owner:|\bTODO\b|\bTBD\b' "$1" && return 1 || return 0
}

while IFS=$'\x1f' read -r id kind required run evidence title; do
  result=""; detail=""
  case "$kind" in
    command)
      if out=$(bash -c "$run" 2>&1); then result=PASS; detail="$run"
      else result=FAIL; detail="$run — $(printf '%s' "$out" | tail -1 | cut -c1-120)"; fi
      ;;
    evidence)
      if [ ! -f "$evidence" ]; then result=OPEN; detail="missing: $evidence"
      elif ! check_placeholders "$evidence"; then result=OPEN; detail="$evidence has placeholders"
      elif ! grep -q "$SHORT" "$evidence"; then result=OPEN; detail="$evidence does not name candidate $SHORT"
      else result=PASS; detail="$evidence names $SHORT"; fi
      ;;
    human)
      rec="release/approvals/$id.md"
      if [ ! -f "$rec" ]; then result=OPEN; detail="no approval record: $rec"
      else
        missing=""
        for f in Decision By Role Date Commit; do grep -qiE "^\**$f\**:" "$rec" || missing="$missing $f"; done
        if [ -n "$missing" ]; then result=OPEN; detail="$rec lacks:$missing"
        elif ! grep -iE '^\**Commit\**:' "$rec" | grep -q "$SHORT"; then result=OPEN; detail="$rec is for another commit (candidate $SHORT)"
        elif ! grep -iE '^\**Decision\**:' "$rec" | grep -qiE 'approved|pass|accept'; then result=OPEN; detail="$rec records no approval: $(grep -iE '^\**Decision\**:' "$rec" | head -1 | cut -c1-80)"
        else result=PASS; detail="$rec"; fi
      fi
      ;;
  esac
  case "$result" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; OPEN) open=$((open+1));; esac
  printf '%-36s %-8s %-6s %s\n' "$id" "$result" "$required" "$detail"
done < "$GATEFILE"

echo
echo "candidate $CANDIDATE — $pass PASS, $fail FAIL, $open OPEN"
if [ "$fail" -eq 0 ] && [ "$open" -eq 0 ]; then
  echo "RELEASE CHECK: every required gate passes for $SHORT. Status is READY FOR APP REVIEW only once the distribution-archive gate's build is the one uploaded."
  exit 0
fi
echo "RELEASE CHECK: BLOCKED — $open gate(s) open, $fail failed. Each OPEN line names the exact remaining action."
exit 1
