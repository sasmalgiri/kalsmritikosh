//
//  ForensicEngagementTests.swift
//  KalsmritikoshTests
//
//  Persona studio #4 — the forensic expert report must satisfy the FRCP
//  26(a)(2)(B)/Daubert disciplines: named method (indirect justified), sourced
//  schedule, findings distinct from opinion, certainty declared.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Forensic accounting studio")
struct ForensicEngagementTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stage gates enforce the Daubert disciplines")
    func stages() {
        var f = ForensicEngagement(title: "x", now: t0)
        #expect(ForensicEngagement.Stage.allCases.map(\.title) ==
                ["Engagement", "Materials", "Method", "Tracing schedule", "Findings & opinion"])
        // Method: an INDIRECT method requires justification; a direct one doesn't.
        f.methodID = "indirect.networth"
        #expect(!f.isComplete(.method))
        f.methodJustification = "Ledgers destroyed; direct tracing impossible."
        #expect(f.isComplete(.method))
        f.methodID = "direct.specific"; f.methodJustification = ""
        #expect(f.isComplete(.method))
        // Schedule rows must carry a source document.
        var t = FATransaction(); t.date = "2026-01-01"; t.descriptionText = "wire"; t.amount = "100"
        f.schedule = [t]
        #expect(!f.isComplete(.schedule))
        t.sourceDoc = "stmt.pdf p.1"; f.schedule = [t]
        #expect(f.isComplete(.schedule))
        // Opinion requires findings + text + the certainty declaration.
        f.findings = ["fact"]; f.opinion = "opinion"
        #expect(!f.isComplete(.opinion))
        f.certaintyDeclared = true
        #expect(f.isComplete(.opinion))
    }

    @Test("The report is the 26(a)(2)(B) hardcopy, sections in order, with the schedule total")
    func hardcopy() {
        let md = FAReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        #expect(md.contains("Fed. R. Civ. P. 26(a)(2)(B)"))
        let sections = ["1. Engagement & scope", "2. Qualifications", "3. Materials relied upon",
                        "4. Methodology", "5. Tracing schedule", "6. Findings of fact", "7. Opinion", "8. Limitations"]
        var last = md.startIndex
        for s in sections {
            let r = md.range(of: s, range: last..<md.endIndex)
            #expect(r != nil, "missing or out-of-order section: \(s)")
            if let r { last = r.upperBound }
        }
        // Named method + discipline; sourced schedule columns; computed total (18400+18400+30000).
        #expect(md.contains("Specific identification (direct tracing)"))
        #expect(md.contains("state the method used"))
        #expect(md.contains("| # | Date | Description | Payer | Payee | Amount | Account | Source document |"))
        #expect(md.contains("Schedule total: $66800.00"))
        // Findings vs opinion separation + certainty.
        #expect(md.contains("factual observations; the opinion below"))
        #expect(md.contains("reasonable degree of professional certainty"))
        // Limitations state what was NOT produced and what is NOT opined.
        #expect(md.contains("was not produced"))
        #expect(md.contains("No opinion is offered on intent"))
    }

    @Test("A whole engagement survives a JSON round-trip")
    func codable() throws {
        let original = [ForensicEngagement.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([ForensicEngagement].self, from: data) == original)
    }
}
