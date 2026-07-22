//
//  BlockSemanticsTests.swift
//  KalsmritikoshTests
//
//  SEM-002 — open, extensible block-role registry (generic recognizers + domain-pack
//  registration).
//

import Testing
@testable import Kalsmritikosh

@Suite("SEM-002 BlockSemantics")
struct BlockSemanticsTests {

    private let reg = BlockSemanticsRegistry.generic

    @Test("Generic recognizers tag amount, date, employment, clause, contact")
    func genericRecognizers() {
        #expect(reg.tags(forText: "Amount ₹3,800 paid").contains { $0.role == "amountLine" })
        #expect(reg.tags(forText: "Signed on 12/01/2024").contains { $0.role == "dateLine" })
        #expect(reg.tags(forText: "Worked as PPIC Executive").contains { $0.role == "employmentEntry" })
        #expect(reg.tags(forText: "The party shall hereby indemnify").contains { $0.role == "clause" })
        #expect(reg.tags(forText: "reach me at a@b.com").contains { $0.role == "contactLine" })
    }

    @Test("A neutral block gets no tags (no false roles)")
    func noFalseTags() {
        #expect(reg.tags(forText: "Hello, hope you are well.").isEmpty)
    }

    @Test("Registry is OPEN — a domain pack can register a new role")
    func extensible() {
        let extended = reg.registering(BlockRecognizer(name: "doseLine") { text, _ in
            text.lowercased().contains("mg") ? BlockSemanticTag(role: "doseLine", confidence: 0.8, recognizedBy: "doseLine") : nil
        })
        #expect(extended.tags(forText: "Take 500 mg twice daily").contains { $0.role == "doseLine" })
        // Original registry unaffected (immutability).
        #expect(!reg.tags(forText: "Take 500 mg twice daily").contains { $0.role == "doseLine" })
    }

    @Test("Tags are ordered by confidence")
    func orderedByConfidence() {
        let tags = reg.tags(forText: "Amount ₹3,800 paid on 12/01/2024")
        if tags.count >= 2 { #expect(tags[0].confidence >= tags[1].confidence) }
    }
}
