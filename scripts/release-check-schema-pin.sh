#!/bin/bash
# The schema version the code migrates to must be the one the migration matrix test pins
# (memory: a bumped latestVersion without the pin shipped untested upgrades once).
set -uo pipefail
cd "$(dirname "$0")/.."
code=$(grep -oE 'static let latestVersion\s*=\s*[0-9]+' Kalsmritikosh/Storage/Schema/SchemaMigrations.swift | grep -oE '[0-9]+$' | head -1)
pin=$(grep -oE 'latestVersion == [0-9]+' KalsmritikoshTests/MigrationMatrixTests.swift | grep -oE '[0-9]+$' | head -1)
if [ -z "$code" ] || [ -z "$pin" ]; then echo "could not read the schema version (code=$code pin=$pin)"; exit 1; fi
if [ "$code" != "$pin" ]; then echo "schema v$code in code, v$pin pinned in MigrationMatrixTests"; exit 1; fi
echo "schema v$code pinned"
