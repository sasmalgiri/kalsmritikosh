#!/usr/bin/env bash
# N1 (mandate 2026-11-01): the release checker must reject negative approvals, malformed/empty manifests,
# unknown gate kinds, duplicate ids, another commit's records and digest mismatches — and pass the
# positive controls. Runs against throwaway git repositories; never touches release/ records.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -W ignore "$HERE/../../scripts/tests/test_release_check.py" 2>&1 | tail -3
rc=${PIPESTATUS[0]}
# §5 — the debug-only launch-argument guard (scripts/release-check-debug-args.sh) flags an argument or type
# outside `#if DEBUG` (incl. the GUI walk's --ui-walk-simulated-plan) and passes a wrapped one.
python3 -W ignore "$HERE/../../scripts/tests/test_release_check_debug_args.py" 2>&1 | tail -3
rc2=${PIPESTATUS[0]}
[ "$rc" -ne 0 ] && exit "$rc"
exit "$rc2"
