#!/bin/bash
#
# generate-kalverify.sh — build the single-file standalone verifier from the
# app's OWN conformance source files (Phase A, seventh audit).
#
# verifier/kalverify.swift is GENERATED: the shared core (rule model,
# compiler, evaluator, rollup, canonicalization, envelope) is concatenated
# byte-for-byte from the app target, followed by the CLI-only tail
# (verifier/kalverify.main.swift). App/CLI parity is therefore structural —
# there is no second implementation to drift.
#
# CI regenerates and fails if the committed file differs (see build-and-guard).
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="verifier/kalverify.swift"
CORE_FILES=(
  "Kalsmritikosh/Core/LegalNotice.swift"
  "Kalsmritikosh/Personas/Investigator/EvidentiaryStandard.swift"
  "Kalsmritikosh/Personas/PersonaJobKind.swift"
  "Kalsmritikosh/Sutra/JobTooling.swift"
  "Kalsmritikosh/Sutra/Sutra.swift"
  "Kalsmritikosh/Sutra/SutraConformance.swift"
  "Kalsmritikosh/Sutra/SutraRules.swift"
  "Kalsmritikosh/Core/Security/ConformanceEnvelope.swift"
)

{
  cat << 'HEADER'
//
//  kalverify.swift — standalone Kalsmritikosh conformance-bundle verifier.
//
//  ⚠️ GENERATED FILE — do not edit by hand. Regenerate with:
//      scripts/generate-kalverify.sh
//
//  This file is the app's OWN conformance core (rule model, compiler,
//  evaluator, rollup, canonical JSON, seal envelope) concatenated verbatim
//  from the application sources, followed by a thin command-line tail.
//  The verifier therefore reruns EXACTLY the code the app ran — parity is
//  structural, not maintained by hand. CI fails if this file is stale.
//
//  Runs OUTSIDE the app: only Foundation + CryptoKit.
//  Usage:  swift kalverify.swift <bundle-folder> [trusted-signer-key-id]
//  Spec:   docs/verification/BUNDLE_FORMAT.md
//
import Foundation
import CryptoKit
HEADER
  for f in "${CORE_FILES[@]}"; do
    echo ""
    echo "// ═══════════ BEGIN shared app core: $f ═══════════"
    # Strip import lines — the header imports once; duplicates are legal but noisy.
    grep -v '^import ' "$f"
    echo "// ═══════════ END shared app core: $f ═══════════"
  done
  echo ""
  echo "// ═══════════ CLI tail: verifier/kalverify.main.swift ═══════════"
  grep -v '^import ' "verifier/kalverify.main.swift"
} > "$OUT"

# The generated file must FULLY typecheck standalone (not merely parse).
xcrun swiftc -typecheck "$OUT"
echo "generated $OUT ($(wc -l < "$OUT" | tr -d ' ') lines) — typecheck OK"
