#!/usr/bin/env bash
# Unified path R2-E — SIMULATED TestFlight / StoreKit run (SHIP-06, SHIP-09, QA-13).
# Runs the paths SHIP-09 names in the test host, each against the local StoreKit configuration
# (StoreKit/Kalsmritikosh.storekit via SKTestSession) or the simulated services: purchase, trial, restore, refund,
# lapse, plan change (PurchaseStoreKitTests); team/contributor entitlements (SimulatedTeamIdentityTests); upgrade
# (MigrationMatrixTests); first use and deep map work (journey suites); AI consent (SimulatedReleaseTests network
# observation); export and restore (SimulatedReleaseTests clean-profile restore). Each path gets an observed result
# or an explicit blocker. Real Sandbox / TestFlight purchases on supported hardware are still needed.
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/testflight-storekit.md"
sim_banner "$R" "TestFlight / StoreKit journeys (SKTestSession and simulated services, not TestFlight)"
echo "## Paths" >> "$R"
status=0
run() { echo "### $1" >> "$R"; shift; sim_run_tests "$R" "$@" || status=1; }
run "Purchase, trial, restore, refund, lapse, plan change (StoreKit test session)" KalsmritikoshTests/PurchaseStoreKitTests
run "Team and contributor entitlements (simulated policy)" "KalsmritikoshTests/SimulatedTeamIdentityTests/journeys()"
run "Upgrade from older ledgers" KalsmritikoshTests/MigrationMatrixTests
run "First use and deep map work" KalsmritikoshTests/BaseCaseJourneyTests KalsmritikoshTests/SmartMapAcceptanceJourneyTests
run "AI consent (no send without consent; Private sends nothing)" "KalsmritikoshTests/SimulatedReleaseTests/networkObservationByMode()"
run "Export and restore on a clean profile" "KalsmritikoshTests/SimulatedReleaseTests/cleanProfileRestore()"
cat >> "$R" <<'EOF'

## Explicit blockers (not simulated away)
- TestFlight build processing and install on supported hardware: owner (App Store Connect).
- Sandbox Apple ID purchases, real refunds through Apple: owner.
- AI consent path end to end with a real send: needs the deployed relay or the person's key on the signed build.
- Team intake across two Macs with real accounts: needs a real team service (the simulation covers the protocol).
EOF
sim_cleanup_derived
exit $status
