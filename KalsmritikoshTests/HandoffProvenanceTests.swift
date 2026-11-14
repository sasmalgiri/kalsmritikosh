//
//  HandoffProvenanceTests.swift
//  KalsmritikoshTests
//
//  Autonomous completion mandate 2026-11-01, N5 — a carried row is the SAVED row: the ledger's text,
//  references and review decision under the saved revision's real digest, never the caller's copy. A
//  changed in-memory row is an unsaved edit; a stored payload that no longer matches its digest is
//  unreadable (named, not dropped); a record from another case is refused; and every citation of a
//  carried row is printed in the report, not counted.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("N5 — handoff provenance and complete citations", .serialized)
struct HandoffProvenanceTests {

    @Test("The caller's altered row, a tampered stored payload and another case's record are refused; the saved row is what travels; both citations are printed")
    func persistedRowTravels() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt",
                                                            text: "The board approved the payment on 3 March 2026. The treasurer said no approval was given before 5 March.")
        let results = JobResultRepository(database: f.db)
        let q1 = "The board approved the payment on 3 March 2026.", q2 = "The treasurer said no approval was given before 5 March."
        var row = JobResultRow(title: "Approval date disputed", detail: nil, date: "2026-03-03",
                               refs: [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[0], quote: q1),
                                      StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[1], quote: q2)])
        row.decision = JobRowDecision.accepted
        let id = try await results.save(caseID: f.caseID, jobID: "inv.chronology", family: .chronologyLinkage, state: .draft,
                                        content: JobResultContent(rows: [row]), actor: "Ada")
        let saved = try #require(try await results.record(id: id))

        // 1. The caller's copy with a changed row (text and decision) under the real id: an unsaved edit.
        var altered = saved.content
        altered.rows[0].title = "Approval given on 3 March (undisputed)"
        altered.rows[0].decision = JobRowDecision.rejected
        let forgedCopy = JobResultRecord(id: saved.id, caseID: saved.caseID, jobID: saved.jobID, family: saved.family, state: saved.state,
                                         content: altered, createdBy: saved.createdBy, createdAt: saved.createdAt)
        await #expect(throws: JobResultExportError.unsavedEdits) {
            _ = try await JobResultHandoff.addToChronology(forgedCopy, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        }
        // 2. The same id presented as another case's: refused before anything is written.
        let otherCase = JobResultRecord(id: saved.id, caseID: UUID(), jobID: saved.jobID, family: saved.family, state: saved.state,
                                        content: saved.content, createdBy: saved.createdBy, createdAt: saved.createdAt)
        await #expect(throws: CaseFileError.staleResultRevision) {
            _ = try await JobResultHandoff.addToChronology(otherCase, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        }
        #expect(try await f.svc.snapshot(caseID: f.caseID, custody: [])?.journal.filter { $0.kind == .chronology }.isEmpty == true)

        // 3. The saved row travels, with both citations; the report prints the second in full.
        try await JobResultHandoff.addToChronology(saved, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        let snap = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let entry = try #require(snap.journal.first { $0.kind == .chronology })
        #expect(entry.text == "Approval date disputed" && entry.citations.count == 2)
        let report = CaseFileDocuments.caseFileReport(snap, by: "Ada")
        #expect(report.contains("Citation 2 of 2: “\(q2)”"), "the contrary passage is in the report, not a count")
        #expect(!report.contains("more citation(s)"))

        // 4. The stored payload altered behind the digest: the record is unreadable (named), never skipped.
        try await f.db.exec("UPDATE job_results SET payload_json = REPLACE(payload_json, 'disputed', 'settled') WHERE id = ?;", [.uuid(id)])
        await #expect(throws: JobResultError.unreadable(resultID: id, jobID: "inv.chronology")) {
            _ = try await results.record(id: id)
        }
        await #expect(throws: JobResultError.unreadable(resultID: id, jobID: "inv.chronology")) {
            _ = try await JobResultHandoff.addToReport(saved, row: 0, include: true, results: results, caseFiles: f.svc, actor: "Ada")
        }
        await #expect(throws: JobResultError.self, "a damaged current revision is not replaced by an older one") {
            _ = try await results.latest(caseID: f.caseID, jobID: "inv.chronology")
        }
    }

    @Test("Further citations print their passage and locator")
    func furtherCitationsRender() {
        let v = UUID(), o = UUID(), b = UUID()
        let refs = [StudioEvidenceRef(sourceVersionID: v, quote: "first"),
                    StudioEvidenceRef(sourceVersionID: v, objectID: o, blockID: b, quote: "second passage")]
        let out = CaseFileDocuments.furtherCitations(refs)
        #expect(out.contains("Citation 2 of 2: “second passage” [version \(v.uuidString); document \(o.uuidString.prefix(8)); block \(b.uuidString.prefix(8))]"))
        #expect(CaseFileDocuments.furtherCitations(Array(refs.prefix(1))).isEmpty)
    }
}
