//
//  ReconstructionGoldCasesTests.swift
//  KalsmritikoshTests
//
//  REC-004 — seven mixed-source reconstruction gold cases. Each exercises the deterministic
//  reconstruction (REC-003) + the outline-first gate (REC-001) on a distinct shape, asserting
//  the gates hold: correct chronological order, precision respected, undated separated,
//  citations present, and narrative constrained to the outline's dates.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("REC-004 reconstruction gold cases")
struct ReconstructionGoldCasesTests {

    private let recon = DeterministicReconstruction()
    private let gate = ReconstructionOutlineGate()
    private let ko = UUID()

    private func ev(_ title: String, _ y: Int, _ m: Int, _ d: Int,
                    precision: DatePrecision = .day, conf: Double = 0.9) -> Event {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Event(kind: Event.Kind.allCases.first!, date: Calendar(identifier: .gregorian).date(from: c)!,
                     title: title, sourceObjectID: ko, dateConfidence: conf, datePrecision: precision)
    }

    // 1. Employment history (résumé + emails) — chronological order.
    @Test("Case 1: employment history orders by date")
    func case1_employment() {
        let o = recon.outline(from: [ev("Joined Orchid", 2004, 12, 1), ev("Moved to Hospira", 2013, 6, 1)])
        #expect(o.dated.map(\.title) == ["Joined Orchid", "Moved to Hospira"])
    }

    // 2. Mixed precision (year-only + exact day) — precision respected.
    @Test("Case 2: mixed precision keeps year-only as year")
    func case2_precision() {
        let o = recon.outline(from: [ev("Filed", 2011, 1, 1, precision: .year), ev("Granted", 2014, 3, 12)])
        #expect(o.dated.first?.dateLabel == "2011")
        #expect(o.dated.last?.dateLabel.contains("Mar") == true)
    }

    // 3. Undated event — separated, not forced onto the line.
    @Test("Case 3: undated event separated")
    func case3_undated() {
        let o = recon.outline(from: [ev("Dated", 2020, 1, 1),
                                     ev("Unknown", 1970, 1, 1, precision: .unknown, conf: 0.1)])
        #expect(o.dated.count == 1 && o.undated.count == 1)
    }

    // 4. Same-day events — stable deterministic order.
    @Test("Case 4: same-day events deterministic")
    func case4_sameDay() {
        let a = recon.outline(from: [ev("B", 2020, 5, 1), ev("A", 2020, 5, 1)])
        let b = recon.outline(from: [ev("A", 2020, 5, 1), ev("B", 2020, 5, 1)])
        #expect(a.dated.map(\.title) == b.dated.map(\.title))   // stable regardless of input order
    }

    // 5. Every line cited.
    @Test("Case 5: reconstruction cites sources")
    func case5_cited() {
        #expect(recon.render(from: [ev("X", 2019, 2, 2)]).contains("src "))
    }

    // 6. Narrative constrained: a year not in the outline is flagged.
    @Test("Case 6: ungrounded narrative year flagged")
    func case6_constraint() {
        let v = gate.check(narrative: "In 2004 he joined; in 2099 he retired.", events: [ev("Joined", 2004, 1, 1)])
        #expect(v.ungroundedDates.contains("2099"))
    }

    // 7. Empty evidence — honest, no fabricated timeline.
    @Test("Case 7: empty evidence yields honest message")
    func case7_empty() {
        #expect(recon.render(from: []).contains("No dated events"))
    }
}
