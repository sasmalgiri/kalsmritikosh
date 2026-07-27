#!/usr/bin/env bash
# Guard: sensitive-scope-mutation-bypass
#
# Prevent production code from calling SensitiveScopeRepository.assign() or
# .revoke() directly. All production mutations must go through
# SensitiveScopeMutationService so that sensitiveScopeRevision increments
# automatically and open viewers revalidate in real time.
#
# Uses syntax-resilient matching: '\.(assign|revoke)[[:space:]]*\(' catches both
# same-line and multiline Swift call forms, i.e. it is not defeated by
#     repository.assign(
#         target: target,     ← argument on the next line
#         ...
#     )
#
# Exclusions:
#   - Core/Security/SensitiveScopeMutationService.swift  (the allowed caller)
#   - Storage/Repositories/SensitiveScopeRepository.swift (the implementation)
#
# Test files live under KalsmritikoshTests/ which is outside Kalsmritikosh/,
# so the grep scope automatically excludes them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VIOLATIONS=$(grep -rnE \
    --include="*.swift" \
    '\.(assign|revoke)[[:space:]]*\(' \
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
