#!/usr/bin/env bash
# JOB-DOC — generate the compiled JobDocumentation catalog from the
# authoritative PERSONA_JOB_COVERAGE_MATRIX.csv. Re-run after editing the CSV;
# JobDocumentationDriftTests fails CI if the committed catalog drifts from it.
#   bash scripts/generate-job-docs.sh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/generate_job_docs.py > Kalsmritikosh/Personas/JobDocumentationGenerated.swift
echo "Wrote Kalsmritikosh/Personas/JobDocumentationGenerated.swift"
