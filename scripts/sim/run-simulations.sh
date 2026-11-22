#!/usr/bin/env bash
# Unified path R2-E — the test phase's entry point for every SIMULATED row (QA-23). Runs the in-process simulations
# (team identity, AI provider and held-out sets, agent-participant study, release rows), the relay's simulated
# deploy, and each release-run script. Each step's report lands in $SIM_OUT; INDEX.md lists them.
# usage: scripts/sim/run-simulations.sh [--skip-build-runs]   (--skip-build-runs: no Release build / app launch)
source "$(dirname "$0")/lib.sh"
INDEX="$SIM_OUT/INDEX.md"
sim_banner "$INDEX" "simulation index (QA-23)"
status=0

echo "## In-process simulations (test host)" >> "$INDEX"
sim_run_tests "$INDEX" KalsmritikoshTests/SimulatedTeamIdentityTests KalsmritikoshTests/SimulatedAIAndStudyTests \
  KalsmritikoshTests/SimulatedReleaseTests || status=1

echo "## Relay (simulated staging deploy, in-process)" >> "$INDEX"
if (cd relay && node --test test/simulated-deploy.test.ts > "$SIM_OUT/relay-simulated-deploy.txt" 2>&1); then
  echo "- relay simulated deploy: passed (relay-simulated-deploy.txt)" >> "$INDEX"
else echo "- relay simulated deploy: FAILED (relay-simulated-deploy.txt)" >> "$INDEX"; status=1; fi

echo "## Release-run scripts" >> "$INDEX"
for s in migration-matrix.sh rollout-rollback.sh network-observation.sh test-isolation.sh; do
  if bash "scripts/sim/$s" >> "$SIM_OUT/runner.log" 2>&1; then echo "- $s: completed" >> "$INDEX"; else echo "- $s: FAILED" >> "$INDEX"; status=1; fi
done
for s in disclosure-reconcile.py agent-decision-record.py defect-recheck.py; do
  if python3 "scripts/sim/$s" >> "$SIM_OUT/runner.log" 2>&1; then echo "- $s: completed" >> "$INDEX"; else echo "- $s: FAILED" >> "$INDEX"; status=1; fi
done
if [ "${1:-}" != "--skip-build-runs" ]; then
  for s in release-candidate.sh testflight-storekit.sh window-journeys.sh; do
    if bash "scripts/sim/$s" >> "$SIM_OUT/runner.log" 2>&1; then echo "- $s: completed" >> "$INDEX"; else echo "- $s: FAILED" >> "$INDEX"; status=1; fi
  done
fi
sim_cleanup_derived
echo; echo "Reports: $SIM_OUT"
exit $status
