#!/usr/bin/env python3
"""Generate JobDocumentationGenerated.swift from PERSONA_JOB_COVERAGE_MATRIX.csv.

The CSV is the authoritative job-documentation source (governance doc); this
emits a compiled Swift catalog so the app carries it without a runtime CSV
parse or a bundled resource. JobDocumentationDriftTests re-parses the CSV and
checks parity, so the catalog can never silently drift.
"""
import csv, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CSV = ROOT / "PERSONA_JOB_COVERAGE_MATRIX.csv"

def swift_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def split_list(cell: str):
    # The matrix uses ';' as the in-cell list separator.
    return [p.strip() for p in cell.split(";") if p.strip()]

def swift_array(cell: str) -> str:
    items = split_list(cell)
    if not items:
        return "[]"
    return "[" + ", ".join(swift_string(i) for i in items) + "]"

def main():
    rows = []
    with open(CSV, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append(r)

    out = []
    out.append("//")
    out.append("//  JobDocumentationGenerated.swift")
    out.append("//  Kalsmritikosh")
    out.append("//")
    out.append("//  GENERATED — do not hand-edit. Source of truth:")
    out.append("//  PERSONA_JOB_COVERAGE_MATRIX.csv. Regenerate with")
    out.append("//  scripts/generate-job-docs.sh; JobDocumentationDriftTests enforces parity.")
    out.append("//")
    out.append("")
    out.append("import Foundation")
    out.append("")
    out.append("enum JobDocumentationGenerated {")
    out.append("    static let all: [JobDocumentation] = [")
    for r in rows:
        out.append("        JobDocumentation(")
        out.append(f"            jobID: {swift_string(r['JobID'].strip())},")
        out.append(f"            persona: {swift_string(r['Persona'].strip())},")
        out.append(f"            name: {swift_string(r['JobName'].strip())},")
        out.append(f"            workflow: {swift_string(r['Workflow'].strip())},")
        out.append(f"            requiredInputs: {swift_array(r['RequiredInputs'])},")
        out.append(f"            methods: {swift_array(r['Methods'])},")
        out.append(f"            workProducts: {swift_array(r['WorkProducts'])},")
        out.append(f"            humanDecisions: {swift_array(r['HumanDecisions'])},")
        out.append(f"            prohibitedConclusions: {swift_array(r['ProhibitedOutcomes'])}),")
    out.append("    ]")
    out.append("}")
    out.append("")
    sys.stdout.write("\n".join(out))

if __name__ == "__main__":
    main()
