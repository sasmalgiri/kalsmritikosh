//
//  CaseFactAttestationTests.swift
//  KalsmritikoshTests
//
//  N3 (2026-11-03) — a "verified" mark only a person can set on a chronology entry (schema v169).
//  The table is append-only; a mark names the person, the date and the entry's digest and is logged;
//  a blank name, a duplicate mark, another case's entry and a withdrawal without a reason are refused;
//  a changed or superseded entry reads "verified on an earlier version"; the report prints the
//  person's mark beside the app's check; case erasure removes the rows.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("N3 — a person's verified mark on a chronology entry (v169)")
struct CaseFactAttestationTests {

    static func entry(_ f: CaseFileTests.Fixture, text: String = "Payment approved by the finance lead") async throws -> UUID {
        try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: text,
                                    eventDate: Date(timeIntervalSince1970: 1_710_000_000), evidenceRef: nil, actor: "Ada")
    }

    @Test("v169 creates case_fact_attestations with its index and append-only triggers; UPDATE and DELETE abort")
    func migrationShape() async throws {
        let f = try await CaseFileTests.fixture()
        let objects = try await f.db.query("SELECT type, name FROM sqlite_master WHERE tbl_name = 'case_fact_attestations';", [])
            .compactMap { r in r.string(1).map { (r.string(0) ?? "", $0) } }
        let names = Set(objects.map(\.1))
        #expect(names.isSuperset(of: ["case_fact_attestations", "idx_case_fact_attestations_entry",
                                      "case_fact_attestations_fixed", "case_fact_attestations_kept"]))
        let cols = Set(try await f.db.query("PRAGMA table_info(case_fact_attestations);", []).compactMap { $0.string(1) })
        #expect(cols == ["id", "case_id", "journal_entry_id", "state", "attested_by", "attested_at", "note", "entry_digest"])
        let e = try await Self.entry(f)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: nil)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_fact_attestations SET attested_by = 'Someone else';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_fact_attestations;", []) }
        // The CHECKs hold even for a direct write: a blank name, an unknown state, a withdrawal without a reason.
        let digest = String(repeating: "a", count: 64)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_fact_attestations VALUES (?,?,?, 'verified', '  ', 1, NULL, ?);",
                                [.uuid(UUID()), .uuid(f.caseID), .uuid(e), .text(digest)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_fact_attestations VALUES (?,?,?, 'approved', 'Ada', 1, NULL, ?);",
                                [.uuid(UUID()), .uuid(f.caseID), .uuid(e), .text(digest)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_fact_attestations VALUES (?,?,?, 'withdrawn', 'Ada', 1, NULL, ?);",
                                [.uuid(UUID()), .uuid(f.caseID), .uuid(e), .text(digest)])
        }
        #expect(try await f.file.attestations(caseID: f.caseID).count == 1)
    }

    @Test("Marking records the person, the date and the entry's digest, and appends a case_actions row")
    func markRecordsAndLogs() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        let at = Date(timeIntervalSince1970: 1_730_000_000)
        let before = try await f.file.actions(caseID: f.caseID).count
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "  Priya Nair ", note: "Checked against the bank statement", at: at)
        let rows = try await f.file.attestations(caseID: f.caseID)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        let entry = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == e })
        #expect(row.state == .verified && row.attestedBy == "Priya Nair" && row.attestedAt == at && row.note == "Checked against the bank statement")
        #expect(row.entryDigest == CaseFactAttestations.digest(of: entry) && row.entryDigest.count == 64)
        let log = try await f.file.actions(caseID: f.caseID)
        #expect(log.count == before + 1)
        #expect(log.last?.action == "factVerified" && log.last?.actor == "Priya Nair" && log.last?.detail == "Checked against the bank statement")
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(s.factMark(for: entry) == .verified(by: "Priya Nair", at: at))
        #expect(s.factMark(for: entry).screenLabel?.hasPrefix("Verified by Priya Nair · ") == true)
    }

    @Test("A blank name is refused; nothing is written or logged")
    func blankNameRefused() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        let before = try await f.file.actions(caseID: f.caseID).count
        await #expect(throws: CaseFileError.blank("Who verified the entry")) {
            try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "   ", note: "x")
        }
        #expect(try await f.file.attestations(caseID: f.caseID).isEmpty)
        #expect(try await f.file.actions(caseID: f.caseID).count == before)
    }

    @Test("Marking an entry already verified on its current version is refused, naming who and when")
    func duplicateRefused() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        let at = Date(timeIntervalSince1970: 1_730_000_000)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: nil, at: at)
        await #expect(throws: CaseFactAttestationError.alreadyVerified(by: "Priya Nair", at: at)) {
            try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Sam Lee", note: nil)
        }
        #expect(CaseFactAttestationError.alreadyVerified(by: "Priya Nair", at: at).errorDescription?.contains("already verified by Priya Nair on") == true)
        #expect(try await f.file.attestations(caseID: f.caseID).count == 1)
    }

    @Test("Withdrawing needs a reason, becomes the current state, and the entry can be marked again")
    func withdrawNeedsReason() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        await #expect(throws: CaseFactAttestationError.notVerified) {
            try await f.file.withdraw(entryID: e, caseID: f.caseID, by: "Priya Nair", reason: "Nothing to withdraw")
        }
        let t0 = Date(timeIntervalSince1970: 1_730_000_000)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: nil, at: t0)
        await #expect(throws: CaseFileError.blank("The reason for withdrawing the verification")) {
            try await f.file.withdraw(entryID: e, caseID: f.caseID, by: "Priya Nair", reason: "  ")
        }
        let t1 = t0.addingTimeInterval(60)
        try await f.file.withdraw(entryID: e, caseID: f.caseID, by: "Sam Lee", reason: "The date is from the draft, not the signed copy", at: t1)
        let rows = try await f.file.attestations(caseID: f.caseID)
        #expect(rows.map(\.state) == [.verified, .withdrawn])
        let entry = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == e })
        var s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(s.factMark(for: entry) == .withdrawn(by: "Sam Lee", at: t1, reason: "The date is from the draft, not the signed copy"))
        #expect(s.factMark(for: entry).screenLabel == nil)
        #expect(try await f.file.actions(caseID: f.caseID).last?.action == "factVerificationWithdrawn")
        // A second withdrawal is refused; marking again is allowed and is current.
        await #expect(throws: CaseFactAttestationError.notVerified) {
            try await f.file.withdraw(entryID: e, caseID: f.caseID, by: "Sam Lee", reason: "again")
        }
        let t2 = t1.addingTimeInterval(60)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Sam Lee", note: "Signed copy checked", at: t2)
        s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(s.factMark(for: entry) == .verified(by: "Sam Lee", at: t2))
        #expect(s.attestationHistory(for: e).count == 3)
    }

    @Test("An entry changed after marking reads 'verified on an earlier version', and can be marked again")
    func editedEntryIsEarlierVersion() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        let t0 = Date(timeIntervalSince1970: 1_730_000_000)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: nil, at: t0)
        // The entry's text changes underneath the mark.
        try await f.db.exec("UPDATE case_journal SET text = 'Payment approved by the CFO' WHERE id = ?;", [.uuid(e)])
        let entry = try #require(try await f.file.journal(caseID: f.caseID).first { $0.id == e })
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(s.factMark(for: entry) == .earlierVersion(by: "Priya Nair", at: t0))
        #expect(s.factMark(for: entry).screenLabel == "Verified on an earlier version — check again")
        #expect(!s.factMark(for: entry).isCurrentVerification)
        let report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("Payment approved by the CFO · Verified on an earlier version"))
        // The person checks again: the new digest differs, so a new mark is accepted and current.
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: "Rechecked", at: t0.addingTimeInterval(60))
        let after = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(after.factMark(for: entry).isCurrentVerification)
    }

    @Test("A superseded result revision makes the mark 'earlier version' even with the same text")
    func supersededIsEarlierVersion() {
        let entry = CaseJournalEntry(id: UUID(), caseID: UUID(), kind: .chronology, eventDate: nil, text: "x", evidenceRef: nil,
                                     author: "Ada", createdAt: Date(), origin: "job:inv.chronology:\(UUID().uuidString):row:0")
        let at = Date(timeIntervalSince1970: 1_730_000_000)
        let row = CaseFactAttestation(id: UUID(), caseID: entry.caseID, journalEntryID: entry.id, state: .verified, attestedBy: "Ada",
                                      attestedAt: at, note: nil, entryDigest: CaseFactAttestations.digest(of: entry))
        #expect(CaseFactAttestations.mark(for: entry, history: [row], superseded: false) == .verified(by: "Ada", at: at))
        #expect(CaseFactAttestations.mark(for: entry, history: [row], superseded: true) == .earlierVersion(by: "Ada", at: at))
        #expect(CaseFactAttestations.mark(for: entry, history: [], superseded: false) == CaseFactMark.none)
    }

    @Test("Another case's entry, a retracted entry and a journal note are refused")
    func wrongEntryRefused() async throws {
        let f = try await CaseFileTests.fixture()
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Another case", actor: "Ada", at: Date())
        let foreign = try await f.file.addJournal(caseID: other.id, kind: .chronology, text: "Elsewhere", eventDate: Date(), evidenceRef: nil, actor: "Ada")
        await #expect(throws: CaseFileError.notInCase("journal entry", foreign)) {
            try await f.file.markVerified(entryID: foreign, caseID: f.caseID, by: "Priya Nair", note: nil)
        }
        let note = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Call the bank", eventDate: nil, evidenceRef: nil, actor: "Ada")
        await #expect(throws: CaseFactAttestationError.notChronology) {
            try await f.file.markVerified(entryID: note, caseID: f.caseID, by: "Priya Nair", note: nil)
        }
        let gone = try await Self.entry(f, text: "Retracted entry")
        try await f.file.retractJournal(caseID: f.caseID, id: gone, actor: "Ada")
        await #expect(throws: CaseFileError.notInCase("journal entry", gone)) {
            try await f.file.markVerified(entryID: gone, caseID: f.caseID, by: "Priya Nair", note: nil)
        }
        #expect(try await f.file.attestations(caseID: f.caseID).isEmpty)
        #expect(try await f.file.attestations(caseID: other.id).isEmpty)
    }

    @Test("The case report prints the person's mark beside the app's check")
    func reportLine() async throws {
        let f = try await CaseFileTests.fixture()
        let marked = try await Self.entry(f, text: "Invoice 114 received")
        _ = try await Self.entry(f, text: "Invoice 115 received")
        let at = Date(timeIntervalSince1970: 1_730_000_000)
        try await f.file.markVerified(entryID: marked, caseID: f.caseID, by: "Priya Nair", note: nil, at: at)
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("Invoice 114 received · Verified by Priya Nair on \(CaseFileDocuments.d(at))"))
        #expect(report.contains("Invoice 115 received · Not verified by a person"))
        #expect(report.contains("is a person's own verification of the entry"))
    }

    @Test("Erasing the case removes its attestations; another case's stay and still refuse deletion")
    func erasureRemovesAttestations() async throws {
        let f = try await CaseFileTests.fixture()
        let e = try await Self.entry(f)
        try await f.file.markVerified(entryID: e, caseID: f.caseID, by: "Priya Nair", note: nil)
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Kept case", actor: "Ada", at: Date())
        let e2 = try await f.file.addJournal(caseID: other.id, kind: .chronology, text: "Kept", eventDate: Date(), evidenceRef: nil, actor: "Ada")
        try await f.file.markVerified(entryID: e2, caseID: other.id, by: "Priya Nair", note: nil)
        let report = try await CaseEraser(database: f.db).erase(caseID: f.caseID, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await f.file.attestations(caseID: f.caseID).isEmpty)
        #expect(report.rowsErased["case_fact_attestations"] == 1)
        #expect(try await f.file.attestations(caseID: other.id).count == 1)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("DELETE FROM case_fact_attestations WHERE case_id = ?;", [.uuid(other.id)])
        }
    }
}
