//
//  ComplianceBoardTests.swift
//  KalsmritikoshTests
//
//  SOP lifecycle step 6: the board tracks every implemented external SOP at a
//  named edition, computes periodic re-check due-ness, honors owner review
//  overrides, and renders as an exportable hardcopy.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SOP compliance board")
struct ComplianceBoardTests {

    // 2026-08-23 12:00 UTC — the seed verification date.
    private let seedDay = Date(timeIntervalSince1970: 1_787_745_600)

    @Test("Every record is fully described and uniquely identified")
    func seedIntegrity() {
        let ids = ComplianceBoard.records.map(\.id)
        #expect(Set(ids).count == ids.count)
        for r in ComplianceBoard.records {
            #expect(!r.title.isEmpty && !r.governingBody.isEmpty)
            #expect(!r.editionImplemented.isEmpty && !r.implementedIn.isEmpty)
            #expect(r.reviewIntervalDays > 0)
            #expect(r.verifiedOn.count == 10)   // yyyy-mm-dd
        }
    }

    @Test("Periodic checks: not due right after verification, due after the interval, override resets")
    func dueness() {
        let r = SOPRecord(id: "x", title: "T", governingBody: "G", editionImplemented: "E",
                          implementedIn: "I", verifiedOn: "2026-08-23", reviewIntervalDays: 180)
        #expect(!r.isDue(now: seedDay))
        let later = seedDay.addingTimeInterval(181 * 86_400)
        #expect(r.isDue(now: later))
        // Board-level: everything seeded 2026-08-23 is current on that day…
        #expect(ComplianceBoard.due(now: seedDay).isEmpty)
        // …and the 180-day AI Act check comes due first.
        let due = ComplianceBoard.due(now: seedDay.addingTimeInterval(200 * 86_400))
        #expect(due.contains { $0.id == "sop.aiact" })
        // An owner review override clears it.
        let cleared = ComplianceBoard.due(now: seedDay.addingTimeInterval(200 * 86_400),
                                          overrides: ["sop.aiact": "2027-03-01"])
        #expect(!cleared.contains { $0.id == "sop.aiact" })
    }

    @Test("The board renders as a hardcopy with every SOP row and a status")
    func hardcopy() {
        let md = ComplianceBoard.markdown(now: seedDay)
        #expect(md.contains("# SOP Compliance Board"))
        #expect(md.contains("| SOP | Governing body | Edition implemented | Enforced in | Verified | Check |"))
        for r in ComplianceBoard.records { #expect(md.contains(r.title)) }
        #expect(md.contains("✓ current"))
    }
}
