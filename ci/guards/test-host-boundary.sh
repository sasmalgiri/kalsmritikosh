#!/usr/bin/env bash
# N3 (mandate 2026-11-01): test-only configurations are reached through TestHost.isActive alone, which is a
# constant false in Release. A direct read of the XCTest environment marker anywhere else in product code
# would let a Release launch with a test-looking environment take a test path.
set -uo pipefail
cd "$(dirname "$0")/../.."
hits=$(grep -rn "XCTestConfigurationFilePath" Kalsmritikosh KalsmritikoshShare 2>/dev/null | grep "\.swift:" | grep -v "Kalsmritikosh/Core/Security/TestHost.swift" || true)
if [ -n "$hits" ]; then
  echo "::error::Test-host marker read outside TestHost.swift:"; echo "$hits"; exit 1
fi
grep -q "#else" Kalsmritikosh/Core/Security/TestHost.swift && grep -q "static let isActive = false" Kalsmritikosh/Core/Security/TestHost.swift \
  || { echo "::error::TestHost.isActive must be a constant false outside DEBUG"; exit 1; }
echo "Test-host boundary clean (one marker read, Release constant false)."
