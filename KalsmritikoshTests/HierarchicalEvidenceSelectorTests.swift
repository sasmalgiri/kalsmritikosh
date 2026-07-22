//
//  HierarchicalEvidenceSelectorTests.swift
//  KalsmritikoshTests
//
//  RET-004 — within-document chunk selection is by relevance, not document prefix.
//

import Testing
@testable import Kalsmritikosh

@Suite("RET-004 HierarchicalEvidenceSelector")
struct HierarchicalEvidenceSelectorTests {

    private let sel = HierarchicalEvidenceSelector()
    private let qc = QueryPlanCompiler()

    @Test("Selects the matching chunk over an earlier non-matching header (no prefix-only)")
    func relevanceOverPrefix() {
        let plan = qc.compile(intent: UserIntent(kind: .factualLookup, scope: .person("X"),
                              rawQuestion: "Where has X worked?"), category: .fact, queryClass: .ordinary)
        let chunks = [
            "Shirshendu Sasmal — Aurangabad — contact header",     // idx 0: no employment terms
            "Work Experience: PPIC Executive at Orchid Chemicals",  // idx 1: matches employment
        ]
        let picked = sel.selectWithinDocument(chunkTexts: chunks, terms: sel.terms(from: plan), limit: 1)
        #expect(picked == [1])   // the relevant paragraph, not the prefix header
    }

    @Test("Ties keep original order (stable)")
    func stableTies() {
        let picked = sel.selectWithinDocument(chunkTexts: ["nothing here", "also nothing"], terms: ["zzz"], limit: 2)
        #expect(picked == [0, 1])
    }

    @Test("Relevance counts distinct query terms present")
    func relevanceCount() {
        #expect(sel.relevance(ofText: "amount paid was large", terms: ["amount", "paid", "date"]) == 2)
    }

    @Test("Query terms include subject words + field keywords")
    func termDerivation() {
        let plan = qc.compile(intent: UserIntent(kind: .factualLookup, scope: .person("Rajesh Kumar"),
                              rawQuestion: "how much paid?"), category: .fact, queryClass: .ordinary)
        let t = sel.terms(from: plan)
        #expect(t.contains("Rajesh"))
        #expect(t.contains("amount"))
    }
}
