//
//  ChronologyDatePrecisionTests.swift
//  KalsmritikoshTests
//
//  TIME-02 — a date-only chronology entry is not an exact midnight event: its precision and the source's
//  own wording are stored with it (v175) and it is shown with no time. Existing rows become "unknown",
//  except carried entries stored at exactly local midnight, which are "day".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Chronology date precision (TIME-02, v175)")
struct ChronologyDatePrecisionTests {

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("A day-precision entry is stored at that day's midnight, read back as 'day' with its wording, and shown without a time")
    func dayEntryHasNoTime() async throws {
        let f = try await CaseFileTests.fixture()
        // The picker gave 15:30 on the day; the entry is a calendar day, so no time is kept or claimed.
        let id = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Invoice paid", eventDate: Self.local(2026, 3, 12, 15, 30),
                                             evidenceRef: nil, datePrecision: .day, dateText: "the 12th of March 2026", actor: "Ada")
        let e = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == id })
        #expect(e.datePrecision == .day && e.dateText == "the 12th of March 2026")
        #expect(e.eventDate == Self.local(2026, 3, 12))
        let label = try #require(e.dateLabel)
        let day = DateFormatter(); day.dateStyle = .medium; day.timeStyle = .none
        #expect(label == "\(day.string(from: Self.local(2026, 3, 12))) — “the 12th of March 2026”", "no time, no 00:00: \(label)")
        #expect(!label.contains(":"))
        #expect(CaseChronologyTab.dateColumn(e) == label)
    }

    @Test("A minute entry keeps and shows its time; a dated entry with no stated precision is 'unknown' and shown without a time")
    func minuteAndUnknown() async throws {
        let f = try await CaseFileTests.fixture()
        let at = Self.local(2026, 3, 12, 15, 30)
        let m = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Call", eventDate: at, evidenceRef: nil, datePrecision: .minute, actor: "Ada")
        let u = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Meeting", eventDate: at, evidenceRef: nil, actor: "Ada")
        let n = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "A note", eventDate: nil, evidenceRef: nil, datePrecision: .day, dateText: "x", actor: "Ada")
        let all = try await f.file.journal(caseID: f.caseID)
        let minute = try #require(all.first { $0.id == m }), unknown = try #require(all.first { $0.id == u }), note = try #require(all.first { $0.id == n })
        let both = DateFormatter(); both.dateStyle = .medium; both.timeStyle = .short
        #expect(minute.datePrecision == .minute && minute.eventDate == at && minute.dateLabel == both.string(from: at))
        #expect(unknown.datePrecision == .unknown && unknown.eventDate == at, "the stored instant is not changed")
        #expect(unknown.dateLabel?.hasSuffix("(time not known)") == true && unknown.dateLabel?.contains(":") == false)
        // HELP-11 (S12): wording that cannot be placed on a calendar is kept as written; an undated entry claims no precision.
        #expect(note.datePrecision == nil && note.dateText == "x", "an undated note keeps its written date and records no precision")
        // The map's incremental read carries the same fields.
        let delta = try await f.file.journalSince(caseID: f.caseID, afterRowID: 0, known: nil)
        #expect(delta.entries.first { $0.id == m }?.datePrecision == .minute)
    }

    @Test("v175 from a v174 ledger: dated rows become 'unknown', except carried rows at exactly local midnight ('day'); undated rows untouched")
    func migrationV175() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 174)
        let caseID = UUID()
        func row(_ origin: String?, _ date: Date?) async throws -> UUID {
            let id = UUID()
            try await db.exec("""
                INSERT INTO case_journal (id, case_id, entry_kind, event_date, text, author, created_at, origin) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text("chronology"), date.map { .real($0.timeIntervalSince1970) } ?? .null, .text("t"),
                      .text("Ada"), .real(1), origin.map { .text($0) } ?? .null])
            return id
        }
        let carriedMidnight = try await row("passage:abc", Self.local(2026, 1, 5))
        let carriedAfternoon = try await row("passage:def", Self.local(2026, 1, 5, 14, 0))
        let typedMidnight = try await row(nil, Self.local(2026, 1, 5))
        let undated = try await row("passage:ghi", nil)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        func precision(_ id: UUID) async throws -> String? {
            try await db.query("SELECT date_precision FROM case_journal WHERE id = ?;", [.uuid(id)]).first?.string(0)
        }
        #expect(try await precision(carriedMidnight) == "day")
        #expect(try await precision(carriedAfternoon) == "unknown")
        #expect(try await precision(typedMidnight) == "unknown", "a hand-typed entry may really be at midnight: not assumed")
        #expect(try await precision(undated) == nil)
        let kept = try await db.query("SELECT event_date FROM case_journal WHERE id = ?;", [.uuid(carriedAfternoon)]).first?.double(0)
        #expect(kept == Self.local(2026, 1, 5, 14, 0).timeIntervalSince1970, "stored dates are not changed")
        // The CHECK refuses an unknown precision name.
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE case_journal SET date_precision = 'fortnight' WHERE id = ?;", [.uuid(undated)])
        }
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
