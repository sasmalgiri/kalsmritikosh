//
//  DomainFactMergeTests.swift
//  KalsmritikoshTests
//
//  V2 (C-10) — the corroboration-aware merge, owner binding 2026-09-01, #2:
//  the merge key is (subject, field, CANONICAL value), so spellings of one
//  value collapse while a genuine DISAGREEMENT survives as two facts (never
//  averaged away — the evidence gate surfaces it). sourceCount is the
//  invariant: distinct source blocks. And a cross-field mislabel is reassigned
//  to its true field at the source, never surfaced as a second patent.
//
//  Direct unit tests of DomainFactExtractor.merge — pure, no ingest.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V2 C-10 — corroboration merge: spellings collapse, disagreements survive")
struct DomainFactMergeTests {

    private func fact(_ field: String, _ value: String, block: UUID, conf: Double = 0.8) -> GenericFact {
        GenericFact(subjectLabel: "patent", field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }

    @Test("Three spellings of one canonical value collapse to a single fact; sourceCount ≡ distinct blocks")
    func spellingsCollapse() {
        let a = UUID(), b = UUID(), c = UUID()
        let merged = DomainFactExtractor.merge([
            fact("patentNumber", "US1234567B2", block: a),
            fact("patentNumber", "us 1234567 b2", block: b),
            fact("patentNumber", "US1,234,567 B2", block: c),
        ])
        let pat = merged.filter { $0.field == "patentnumber" }
        #expect(pat.count == 1, "three spellings did not collapse: \(pat.map(\.value))")
        #expect(pat.first?.sourceCount == 3, "sourceCount must equal distinct source blocks")
        #expect(Set(pat.first?.sourceBlockIDs ?? []).count == 3)
    }

    @Test("Two genuinely different values under one field survive as two facts — the disagreement is not averaged away")
    func disagreementSurvives() {
        let a = UUID(), b = UUID()
        let merged = DomainFactExtractor.merge([
            fact("patentNumber", "700321", block: a),
            fact("patentNumber", "811444", block: b),
        ])
        let pat = merged.filter { $0.field == "patentnumber" }
        #expect(pat.count == 2, "a true conflict collapsed: \(pat.map(\.value))")
        #expect(Set(pat.map(\.value)) == ["700321", "811444"])
        #expect(pat.allSatisfy { $0.sourceCount == 1 }, "each single-block value keeps sourceCount 1")
    }

    @Test("A cross-field mislabel is reassigned to its true field (blocks preserved, never deleted)")
    func crossFieldMislabelReassigned() {
        let a = UUID(), b = UUID(), c = UUID()
        let merged = DomainFactExtractor.merge([
            fact("patentNumber", "700321", block: a),
            fact("patentNumber", "202398012345", block: b),      // the mislabel
            fact("applicationNumber", "202398012345", block: c),
        ])
        let pat = merged.filter { $0.field == "patentnumber" }.map(\.value)
        let app = merged.filter { $0.field == "applicationnumber" }
        #expect(pat == ["700321"], "mislabel not reassigned out of patentNumber: \(pat)")
        #expect(app.count == 1)
        // The mislabel's evidence block rides along as corroboration for the
        // TRUE field — nothing is deleted; the source still supports the fact.
        #expect(Set(app.first?.sourceBlockIDs ?? []) == [b, c])
        #expect(app.first?.sourceCount == 2, "reassigned block must raise the true field's corroboration")
    }
}
