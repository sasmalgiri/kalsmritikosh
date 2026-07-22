//
//  DeterministicReconstructionTests.swift
//  KalsmritikoshTests
//
//  REC-003 — a model-free reconstruction: chronological, cited, precision-aware, with
//  undated events kept separate rather than forced into a false position.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("REC-003 DeterministicReconstruction")
struct DeterministicReconstructionTests {

    private let recon = DeterministicReconstruction()
    private let ko = UUID()

    private func event(_ title: String, _ date: Date, precision: DatePrecision = .day,
                       dateConfidence: Double = 0.9) -> Event {
        Event(kind: Event.Kind.allCases.first!, date: date, title: title,
              sourceObjectID: ko, dateConfidence: dateConfidence, datePrecision: precision)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Events are ordered strictly by date")
    func chronological() {
        let o = recon.outline(from: [
            event("B", day(2020, 6, 1)),
            event("A", day(2018, 1, 1)),
            event("C", day(2022, 3, 1)),
        ])
        #expect(o.dated.map(\.title) == ["A", "B", "C"])
    }

    @Test("Undated / unknown-precision events are separated, not forced onto the line")
    func undatedSeparated() {
        let o = recon.outline(from: [
            event("dated", day(2020, 1, 1)),
            event("no-date", Date(timeIntervalSince1970: 0), precision: .unknown, dateConfidence: 0.1),
        ])
        #expect(o.dated.map(\.title) == ["dated"])
        #expect(o.undated.map(\.title) == ["no-date"])
    }

    @Test("Year precision renders year-only — no false day precision")
    func precisionRespected() {
        let o = recon.outline(from: [event("joined", day(2004, 12, 3), precision: .year)])
        #expect(o.dated.first?.dateLabel == "2004")
    }

    @Test("Render is cited and states when nothing is available")
    func rendering() {
        #expect(recon.render(from: []).contains("No dated events"))
        let text = recon.render(from: [event("hired", day(2004, 12, 1), precision: .month)])
        #expect(text.contains("Dec 2004"))
        #expect(text.contains("src "))
    }
}
