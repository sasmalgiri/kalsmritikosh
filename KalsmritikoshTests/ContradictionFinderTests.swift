//
//  ContradictionFinderTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ContradictionFinder — Vol 17 §A15")
struct ContradictionFinderTests {
    /// Two events of the same kind for the same primary entity, on
    /// dates > 1 day apart, must surface as a "Multiple <kind> events
    /// for the same subject" conflict.
    @Test("date conflict on same subject + kind")
    func detectsDateConflict() {
        let alice = UUID()
        let cal = Calendar.current
        let dateA = cal.date(from: DateComponents(year: 2025, month: 3, day: 12))!
        let dateB = cal.date(from: DateComponents(year: 2025, month: 3, day: 14))!
        let evA = Event(
            kind: .contractSigned, date: dateA,
            title: "Contract signed on 12th",
            entityIDs: [alice], sourceObjectID: UUID()
        )
        let evB = Event(
            kind: .contractSigned, date: dateB,
            title: "Contract signed on 14th",
            entityIDs: [alice], sourceObjectID: UUID()
        )
        let finder = ContradictionFinder()
        let out = finder.find(events: [evA, evB], links: [])
        #expect(out.count == 1)
        #expect(out[0].description.contains("Multiple contractSigned events"))
    }

    /// A→B + B→A both with causal-claim relations must surface.
    @Test("causal cycle between two events")
    func detectsCausalCycle() {
        let a = Event(kind: .other, date: Date(), title: "A", sourceObjectID: UUID())
        let b = Event(kind: .other, date: Date(), title: "B", sourceObjectID: UUID())
        let links = [
            CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .caused,        confidence: 0.7),
            CausalLink(sourceEventID: b.id, targetEventID: a.id, relation: .contributedTo, confidence: 0.6)
        ]
        let out = ContradictionFinder().find(events: [a, b], links: links)
        #expect(out.contains { $0.description == "Causal cycle between two events" })
    }

    /// Same (source → target) pair carrying both a positive causal
    /// claim AND a PREVENTED relation.
    @Test("opposing causal claims on the same pair")
    func detectsOpposingClaims() {
        let a = Event(kind: .other, date: Date(), title: "A", sourceObjectID: UUID())
        let b = Event(kind: .other, date: Date(), title: "B", sourceObjectID: UUID())
        let links = [
            CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .caused,    confidence: 0.7),
            CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .prevented, confidence: 0.6)
        ]
        let out = ContradictionFinder().find(events: [a, b], links: links)
        #expect(out.contains { $0.description.contains("Opposing causal claims") })
    }

    @Test("empty input produces empty output")
    func emptyInputs() {
        #expect(ContradictionFinder().find(events: [], links: []).isEmpty)
    }
}
