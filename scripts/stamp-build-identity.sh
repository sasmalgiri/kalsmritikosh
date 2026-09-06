#!/usr/bin/env bash
# SPEC A1.5 — stamp BuildIdentity.gitSHA with HEAD's short SHA. The release
# recipe runs this immediately before Product → Archive (the working-tree
# edit is deliberate: the archive carries the stamp; the repo keeps
# "development"). Verify: Settings → About shows this SHA.
set -euo pipefail
cd "$(dirname "$0")/.."
SHA=$(git rev-parse --short=10 HEAD)
sed -i '' "s/public static let gitSHA = \"[^\"]*\"/public static let gitSHA = \"$SHA\"/" \
  Kalsmritikosh/App/BuildIdentity.swift
echo "stamped BuildIdentity.gitSHA = $SHA (working tree only — do not commit)"
