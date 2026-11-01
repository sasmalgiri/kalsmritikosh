#!/bin/bash
#
# release-check.sh — the release-gate command. The checking lives in scripts/release_check.py (N1 of the
# autonomous completion mandate 2026-11-01: the earlier shell parser passed "NOT APPROVED", malformed or
# empty manifests, unknown gate kinds and a failed temp-file setup). See that file for the gate kinds.
# Exit 0 only when every required gate passes; 1 when blocked; 2 when nothing could be checked.
#
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "RELEASE CHECK: ERROR — cannot enter the repository"; exit 2; }
command -v python3 >/dev/null || { echo "RELEASE CHECK: ERROR — python3 is required"; exit 2; }
exec python3 scripts/release_check.py "$@"
