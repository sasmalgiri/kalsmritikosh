//
//  DomainFactExtractorTests.swift
//  KalsmritikoshTests
//
//  SEM-004…008 unification — one facade runs all packs; a mixed document yields facts from
//  each relevant pack, and duplicate (field,value) pairs merge their evidence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("DomainFactExtractor")
struct DomainFactExtractorTests {

    private let extractor = DomainFactExtractor()
    private let blk = UUID()

    @Test("A résumé yields employment facts")
    func resume() {
        let facts = extractor.extract(
            fromText: "Work Experience: PPIC Executive at Orchid Chemicals Ltd since Dec 2004.",
            subjectLabel: "Sasmal", blockID: blk)
        #expect(facts.contains { $0.field == "employer" && $0.value.contains("Orchid") })
    }

    @Test("A receipt yields amount + counterparty facts")
    func receipt() {
        let facts = extractor.extract(fromText: "Paid to Rajesh Kumar. Amount ₹3,800 on 12/01/2024.",
                                      subjectLabel: "payment", blockID: blk)
        let fields = Set(facts.map(\.field))
        #expect(fields.contains("amount"))
        #expect(fields.contains("counterparty"))
    }

    @Test("Every extracted fact is evidence-linked to the block")
    func evidenceLinked() {
        let facts = extractor.extract(fromText: "Amount ₹500 paid to Acme Ltd.", subjectLabel: "p", blockID: blk)
        #expect(!facts.isEmpty)
        #expect(facts.allSatisfy { $0.sourceBlockIDs.contains(blk) })
    }

    @Test("Non-domain text yields no facts (packs stay quiet)")
    func quiet() {
        #expect(extractor.extract(fromText: "Hope you are well.", subjectLabel: "x", blockID: blk).isEmpty)
    }

    @Test("Duplicate (field,value) from overlapping packs merges evidence")
    func merge() {
        let b2 = UUID()
        let dupes = [
            GenericFact(subjectLabel: "s", field: "amount", value: "₹500", status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blk]),
            GenericFact(subjectLabel: "s", field: "amount", value: "₹500", status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [b2]),
        ]
        let merged = DomainFactExtractor.merge(dupes)
        #expect(merged.count == 1)
        #expect(Set(merged[0].sourceBlockIDs) == Set([blk, b2]))
    }
}
