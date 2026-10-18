#!/usr/bin/env bash
# The full case bench: every NTSB and OSHA investigation, then court decisions in batches until
# the target is reached. After each batch the documents are deleted (truth.jsonl and results are
# kept), so disk use stays bounded. Safe to stop and restart: finished shards are skipped and a
# finished batch is not converted again.
#   scripts/casebench/full-run.sh [ROOT=/tmp/casebench] [WORKERS=3] [TARGET=1000000]
set -uo pipefail
ROOT=${1:-/tmp/casebench}; WORKERS=${2:-3}; TARGET=${3:-1000000}
HERE=$(cd "$(dirname "$0")" && pwd)
CASES="$ROOT/cases"; OUT="$ROOT/results"; RAW="$ROOT/raw"
export TEST_RUNNER_CASEBENCH_ASK_EVERY=${ASK_EVERY:-20}
mkdir -p "$CASES" "$OUT"
count() { find "$CASES" -name truth.jsonl -exec cat {} + 2>/dev/null | wc -l | tr -d ' '; }
prune() { find "$CASES" -mindepth 3 -maxdepth 3 -type d -exec rm -rf {} + 2>/dev/null; }   # case folders; truth.jsonl stays
batch() {   # $1 = marker name, rest = converter command
  local mark="$CASES/.done-$1"; shift
  [ -f "$mark" ] && return 0
  "$@" && "$HERE/run.sh" "$CASES" "$OUT" "$WORKERS" 1 && prune && touch "$mark"
}
batch ntsb python3 "$HERE/ntsb.py" "$RAW/avall.mdb" "$RAW/Pre2008.mdb" --out "$CASES"
batch osha python3 "$HERE/osha.py" "$RAW/osha/accident.zip" "$RAW/osha/accident_abstract.zip" "$RAW/osha/accident_injury.zip" --out "$CASES"
REPORTERS=f2d,f3d,f-supp,f-supp-2d,a2d,ne2d,nw2d,p2d,se2d,sw2d,cal-app-3d
k=0
while [ "$(count)" -lt "$TARGET" ] && [ $k -lt 60 ]; do
  batch "cap-$k" python3 "$HERE/cap.py" --out "$CASES" --reporters "$REPORTERS" --skip-volumes $((k * 15)) \
        --volumes-per-reporter 15 --tag "b$(printf %02d $k)"
  k=$((k + 1))
  echo "$(date '+%F %T') batch $k done — $(count) cases converted, $(ls "$OUT"/*.jsonl 2>/dev/null | wc -l | tr -d ' ') shards scored"
done
echo "full run finished: $(count) cases"
