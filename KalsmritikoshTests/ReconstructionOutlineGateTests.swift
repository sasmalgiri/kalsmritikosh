//
//  ReconstructionOutlineGateTests.swift
//  KalsmritikoshTests
//
//  REC-001 — a narrative is constrained by the deterministic outline: dates it asserts must
//  appear in the evidence outline, else they are flagged as ungrounded.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("REC-001 ReconstructionOutlineGate")
struct ReconstructionOutlineGateTests {

    private let gate = ReconstructionOutlineGate()
    private let ko = UUID()

    private func event(_ title: String, year: Int) -> Event {
        var c = DateComponents(); c.year = year; c.month = 1; c.day = 1
        let d = Calendar(identifier: .gregorian).date(from: c)!
        return Event(kind: Event.Kind.allCases.first!, date: d, title: title,
                     sourceObjectID: ko, dateConfidence: 0.9, datePrecision: .year)
    }

    @Test("A narrative using only outline years is constrained")
    func constrained() {
        let v = gate.check(narrative: "In 2004 he joined; by 2011 he moved on.",
                           events: [event("joined", year: 2004), event("moved", year: 2011)])
        #expect(v.isConstrained)
        #expect(v.ungroundedDates.isEmpty)
    }

    @Test("A narrative asserting a year absent from the outline is flagged")
    func ungroundedFlagged() {
        let v = gate.check(narrative: "He joined in 2004 and was promoted in 2015.",
                           events: [event("joined", year: 2004)])
        #expect(!v.isConstrained)
        #expect(v.ungroundedDates.contains("2015"))
    }

    @Test("Outline is available (built before generation)")
    func outlineFirst() {
        let o = gate.outline(for: [event("joined", year: 2004)])
        #expect(o.dated.count == 1)
    }
}
