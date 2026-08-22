//
//  ProfessionalGapTests.swift
//  KalsmritikoshTests
//
//  The two professional-parity gaps closed from BENCHMARK_VS_PROFESSIONAL.md:
//  (1) findings-classification vocabulary; (2) 8D dual root cause (escape).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Findings classification vocabulary")
struct FindingClassificationTests {

    @Test("The four recognized outcomes, each described")
    func vocabulary() {
        let all = FindingClassification.allCases
        #expect(all == [.substantiated, .partiallySubstantiated, .unsubstantiated, .inconclusive])
        #expect(all.allSatisfy { !$0.label.isEmpty && !$0.detail.isEmpty })
        #expect(FindingClassifications.helpSummary.contains("Inconclusive"))
    }

    @Test("The discipline keeps 'unsubstantiated' ≠ dishonest")
    func discipline() {
        let note = FindingClassifications.disciplineNote.lowercased()
        #expect(note.contains("balance of probabilities"))
        #expect(note.contains("didn") && note.contains("bar"))   // "didn't meet the bar"
        #expect(FindingClassification.unsubstantiated.detail.lowercased().contains("not a finding that the complainant was dishonest"))
    }
}

@Suite("RCA dual root cause (8D escape)")
struct RCADualRootCauseTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The report renders the escape cause when present")
    func escapeInReport() {
        let md = RCAReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.contains("escape cause"))
        #expect(md.contains("Why it wasn't caught sooner"))
        // Methodology + opinion labelling from the benchmark pass are present too.
        #expect(md.contains("**Method:**"))
        #expect(md.contains("analyst's opinion"))
    }

    @Test("Analyses saved before the escape field still decode (back-compat)")
    func codableBackCompat() throws {
        // A conclusion JSON WITHOUT escapeRootCause (the old schema).
        let oldJSON = #"{"rootCause":"r","contributingFactors":["a"],"recommendations":["b"],"summary":"s"}"#
        let c = try JSONDecoder().decode(RCAConclusion.self, from: Data(oldJSON.utf8))
        #expect(c.rootCause == "r")
        #expect(c.escapeRootCause == "")          // defaulted, not a decode failure
        // And the new field round-trips.
        var c2 = c; c2.escapeRootCause = "why not caught"
        let data = try JSONEncoder().encode(c2)
        #expect(try JSONDecoder().decode(RCAConclusion.self, from: data).escapeRootCause == "why not caught")
    }
}
