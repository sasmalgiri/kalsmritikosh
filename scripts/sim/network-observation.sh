#!/usr/bin/env bash
# Unified path R2-E — SIMULATED network observation of privacy modes (SEC-09).
# 1. In-process: the app's one network door records every send attempt by mode (SimulatedReleaseTests
#    networkObservationByMode → network-observation.md in $SIM_OUT).
# 2. Process-level (optional, when an installed app path is given): launch it and sample its sockets with nettop for
#    $SECONDS_TO_WATCH seconds, so "no traffic" is observed, not inferred from a mode label. Run once per mode, setting
#    the mode in the app before passing --mode <label>.
# usage: scripts/sim/network-observation.sh [--app /path/To.app --mode private]
# A packet capture of the signed app with real consent changes is still needed for release.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/network-observation-run.md"
sim_banner "$R" "network observation of privacy modes"
APP=""; MODE="unlabelled"; SECONDS_TO_WATCH="${SECONDS_TO_WATCH:-60}"
while [ $# -gt 0 ]; do case "$1" in --app) APP="$2"; shift 2;; --mode) MODE="$2"; shift 2;; *) shift;; esac; done
echo "## App-side door record" >> "$R"
sim_run_tests "$R" "KalsmritikoshTests/SimulatedReleaseTests/networkObservationByMode()" || true
echo "See network-observation.md for the per-mode table." >> "$R"
if [ -n "$APP" ]; then
  echo "## Process sockets (nettop), mode: $MODE" >> "$R"
  open -n "$APP"; sleep 5
  PID="$(pgrep -nf "$APP/Contents/MacOS" || true)"
  HELPERS="$(pgrep -f "KalsmritikoshNetworkHelper" | tr '\n' ' ' || true)"
  if [ -z "$PID" ]; then echo "- the app did not start" >> "$R"; exit 1; fi
  OUT="$SIM_OUT/nettop-$MODE.txt"
  : > "$OUT"
  end=$((SECONDS + SECONDS_TO_WATCH))
  while [ $SECONDS -lt $end ]; do
    for p in $PID $HELPERS; do nettop -P -L 1 -p "$p" -J bytes_in,bytes_out 2>/dev/null | tail -n +2 >> "$OUT" || true; done
    sleep 5
  done
  pkill -f "$APP/Contents/MacOS" || true
  python3 - "$OUT" "$MODE" >> "$R" <<'PY'
import sys
rows=[l.strip() for l in open(sys.argv[1]) if l.strip()]
tot=0
for l in rows:
    parts=[p for p in l.split(",") if p!=""]
    nums=[int(p) for p in parts[-2:] if p.isdigit()]
    tot+=sum(nums)
print("- samples: %d, bytes in+out observed: %d (mode %s)" % (len(rows), tot, sys.argv[2]))
print("- expectation: private → 0 bytes; online-consented → bytes only to the allowed hosts during a send")
PY
fi
sim_cleanup_derived
