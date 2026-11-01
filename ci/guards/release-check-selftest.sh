#!/usr/bin/env bash
# N1 (mandate 2026-11-01): the release checker must reject negative approvals, malformed/empty manifests,
# unknown gate kinds, duplicate ids, another commit's records and digest mismatches — and pass the
# positive controls. Runs against throwaway git repositories; never touches release/ records.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -W ignore "$HERE/../../scripts/tests/test_release_check.py" 2>&1 | tail -3
exit "${PIPESTATUS[0]}"
