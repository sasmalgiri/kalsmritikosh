#!/usr/bin/env bash
# Unified path R2-E — SIMULATED migration and recovery matrix (QA-10).
# Runs the generated-ledger migration matrix (every milestone → latest, preservation + reopen), the backup damage
# matrix (complete / corrupt / truncated / missing / no manifest), then generates an older v160 archive with its
# manifest and runs the REAL-archive acceptance path (ci/migrations/verify-real-archive.sh) on it. A sanitised archive
# from the owner's real history is still needed for release.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/migration-matrix.md"
sim_banner "$R" "migration and recovery matrix over generated older ledgers"
status=0
sim_run_tests "$R" KalsmritikoshTests/MigrationMatrixTests KalsmritikoshTests/SmartMapS18QATests \
  "KalsmritikoshTests/SimulatedReleaseTests/generateOlderArchive()" || status=1
A="$SIM_OUT/archive/sim-history-v160.sqlite"; M="$SIM_OUT/archive/sim-history-v160.json"
if [ -f "$A" ] && [ -f "$M" ]; then
  if bash ci/migrations/verify-real-archive.sh "$A" "$M" > "$SIM_OUT/verify-real-archive.txt" 2>&1; then
    echo "- real-archive path on the generated v160 archive: passed (verify-real-archive.txt)" >> "$R"
  else echo "- real-archive path on the generated v160 archive: FAILED (verify-real-archive.txt)" >> "$R"; status=1; fi
  rm -f "$A" "$A-wal" "$A-shm"            # keep only the manifest (small)
else
  echo "- the generated archive is missing: the generator test did not run" >> "$R"; status=1
fi
sim_cleanup_derived
exit $status
