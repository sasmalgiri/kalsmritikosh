//
//  JobDocumentationDriftTests.swift
//  KalsmritikoshTests
//
//  JOB-DOC — the compiled JobDocumentationCatalog is generated from
//  PERSONA_JOB_COVERAGE_MATRIX.csv (the governance source of truth). This
//  suite re-parses that CSV and fails if the committed catalog drifts, so the
//  in-app job documentation can never silently diverge from the matrix. It
//  also pins the mapping to the persona-job engine: every launchable persona
//  job's coverage-matrix ID has documentation.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("JOB-DOC — documentation matches the coverage matrix")
struct JobDocumentationDriftTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Minimal RFC-4180 row reader (quoted fields may contain commas).
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], field = "", row: [String] = [], inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" { field.append("\""); i = next }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private func splitList(_ s: String) -> [String] {
        s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test("The generated catalog equals the coverage matrix, row for row")
    func catalogMatchesCSV() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("PERSONA_JOB_COVERAGE_MATRIX.csv"), encoding: .utf8)
        let rows = parseCSV(text)
        let header = rows[0]
        func col(_ name: String) -> Int { header.firstIndex(of: name)! }
        let (pJob, pPersona, pName, pWf) = (col("JobID"), col("Persona"), col("JobName"), col("Workflow"))
        let (pIn, pMethods, pWP) = (col("RequiredInputs"), col("Methods"), col("WorkProducts"))
        let (pHD, pProhibited) = (col("HumanDecisions"), col("ProhibitedOutcomes"))

        let dataRows = rows.dropFirst().filter { $0.count >= header.count && !$0[pJob].trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(JobDocumentationCatalog.all.count == dataRows.count,
                "catalog has \(JobDocumentationCatalog.all.count) entries, CSV has \(dataRows.count) — regenerate with scripts/generate-job-docs.sh")

        for r in dataRows {
            let jobID = r[pJob].trimmingCharacters(in: .whitespaces)
            let doc = try #require(JobDocumentationCatalog.doc(forJobID: jobID), "no documentation for \(jobID)")
            #expect(doc.persona == r[pPersona].trimmingCharacters(in: .whitespaces))
            #expect(doc.name == r[pName].trimmingCharacters(in: .whitespaces))
            #expect(doc.workflow == r[pWf].trimmingCharacters(in: .whitespaces))
            #expect(doc.requiredInputs == splitList(r[pIn]))
            #expect(doc.methods == splitList(r[pMethods]))
            #expect(doc.workProducts == splitList(r[pWP]))
            #expect(doc.humanDecisions == splitList(r[pHD]))
            #expect(doc.prohibitedConclusions == splitList(r[pProhibited]), "\(jobID) prohibited-conclusions drift")
        }
    }

    @Test("All five personas are documented and every documented job names a guardrail (prohibited conclusion)")
    func personasAndGuardrails() {
        let personas = Set(JobDocumentationCatalog.all.map(\.persona))
        #expect(personas == ["Investigator", "Researcher", "Journalist", "Lawyer", "Individual"])
        for persona in personas {
            #expect(!JobDocumentationCatalog.docs(forPersona: persona).isEmpty, "\(persona) undocumented")
        }
        // The SAP-style value: every job states what it must NOT conclude.
        let missingGuardrail = JobDocumentationCatalog.all.filter { $0.prohibitedConclusions.isEmpty }.map(\.jobID)
        #expect(missingGuardrail.isEmpty, "jobs missing a prohibited-conclusion guardrail: \(missingGuardrail)")
    }

    @Test("Lookup is case-insensitive and unknown ids return nil")
    func lookupContract() {
        #expect(JobDocumentationCatalog.doc(forJobID: "inv-01") != nil)
        #expect(JobDocumentationCatalog.doc(forJobID: "INV-01") != nil)
        #expect(JobDocumentationCatalog.doc(forJobID: "does-not-exist") == nil)
    }
}
