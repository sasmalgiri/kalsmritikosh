#!/usr/bin/env bash
# Unified path R2-E — SIMULATED rollout and rollback (SHIP-10; also SHIP-13 relay metering and PERF-12 health).
# App side: a ledger written by a newer version is refused by an older one and left unchanged (no destructive
# downgrade). Relay side: an in-process staging deploy → rollout → rollback keeps every count, the D1 schema is
# additive only, the paid plan's send is forwarded once and metered, and the operator health counters are
# content-free. A real staging Worker, `wrangler rollback` and the incident drill are still needed for release.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/rollout-rollback.md"
sim_banner "$R" "rollout and rollback rehearsal"
status=0
echo "## App: no destructive downgrade" >> "$R"
sim_run_tests "$R" "KalsmritikoshTests/SimulatedReleaseTests/rollbackNeverDowngrades()" || status=1
echo "## Relay: staging deploy, rollout, rollback, metering, health (in-process)" >> "$R"
if (cd relay && node --test test/simulated-deploy.test.ts > "$SIM_OUT/relay-simulated-deploy.txt" 2>&1); then
  echo "- passed (relay-simulated-deploy.txt)" >> "$R"; else echo "- FAILED (relay-simulated-deploy.txt)" >> "$R"; status=1; fi
cat >> "$R" <<'EOF'

## Incident response (rehearsed steps, simulated)
1. A failed rollout: stop the phased release in App Store Connect; ship the next patch (forward-only; no downgrade of a newer ledger).
2. A failed relay deploy: `wrangler rollback` to the previous version (D1 changes are additive, so the older code reads the newer tables).
3. Health: GET /v1/health with the operator token shows per-route status classes and latency only (no content).
EOF
sim_cleanup_derived
exit $status
