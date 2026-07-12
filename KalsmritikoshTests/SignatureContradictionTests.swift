//
//  SignatureContradictionTests.swift
//  KalsmritikoshTests
//
//  A5.6 — signatory extraction + ContradictionDetector.detectEventSignatureConflicts
//  (same signing per a shared party, different signatory). Add to the test
//  target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct SignatureContradictionTests {

    // MARK: Extraction

    @Test func signatoryExtraction() {
        #expect(RuleEventExtractor.extractSignatory(from: "This agreement was signed by Alice Martin on Tuesday.") == "alice martin")
        #expect(RuleEventExtractor.extractSignatory(from: "/s/ Bob Chen") == "bob chen")
        #expect(RuleEventExtractor.extractSignatory(from: "No signature present.") == nil)
    }

    // MARK: Detection

    private func signed(_ who: String, source: UUID, parties: [Entity.ID]) -> Event {
        Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 0),
              title: "Contract signed", entityIDs: parties, sourceObjectID: source,
              attributes: ["signatory": AnyCodable(.string(who))])
    }

    @Test func differentSignatorySharedPartyConflicts() {
        let party = UUID()
        let found = ContradictionDetector().detectEventSignatureConflicts([
            signed("alice martin", source: UUID(), parties: [party, UUID()]),
            signed("bob chen", source: UUID(), parties: [party])
        ])
        #expect(found.count == 1)
        #expect(found.first?.kind == .signature)
    }

    @Test func noSharedPartyDoesNotConflict() {
        // Two unrelated contracts (no common party) must not be conflated.
        let found = ContradictionDetector().detectEventSignatureConflicts([
            signed("alice martin", source: UUID(), parties: [UUID()]),
            signed("bob chen", source: UUID(), parties: [UUID()])
        ])
        #expect(found.isEmpty)
    }

    @Test func sameSignatoryDoesNotConflict() {
        let party = UUID()
        let found = ContradictionDetector().detectEventSignatureConflicts([
            signed("alice martin", source: UUID(), parties: [party]),
            signed("alice martin", source: UUID(), parties: [party])
        ])
        #expect(found.isEmpty)
    }
}
