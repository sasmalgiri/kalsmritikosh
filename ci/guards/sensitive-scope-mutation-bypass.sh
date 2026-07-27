#!/usr/bin/env bash
# Guard: sensitive-scope-mutation-bypass
#
# Prevent production code from calling SensitiveScopeRepository.assign() or
# .revoke() directly. All production mutations must go through
# SensitiveScopeMutationService so that sensitiveScopeRevision increments
# automatically and open viewers revalidate in real time.
#
# Exclusions:
#   - Core/Security/SensitiveScopeMutationService.swift  (the allowed caller)
#   - Storage/Repositories/SensitiveScopeRepository.swift (the implementation)
#
# Test files live under KalsmritikoshTests/ which is not under Kalsmritikosh/,
# so the grep scope automatically excludes them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VIOLATIONS=$(grep -rn \
    --include="*.swift" \
    -e "\.assign(target:" \
    -e "\.revoke(assignmentID:" \
    "$ROOT/Kalsmritikosh/" \
    | grep -v "Core/Security/SensitiveScopeMutationService\.swift" \
    | grep -v "Storage/Repositories/SensitiveScopeRepository\.swift" \
    || true)

if [ -n "$VIOLATIONS" ]; then
    echo "::error::Direct SensitiveScopeRepository mutation bypass detected — route through SensitiveScopeMutationService:"
    echo "$VIOLATIONS"
    exit 1
fi
echo "sensitive-scope-mutation-bypass: clean."
