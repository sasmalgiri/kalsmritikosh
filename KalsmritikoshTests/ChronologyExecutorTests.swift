//
//  ChronologyExecutorTests.swift
//  KalsmritikoshTests
//
//  §3 / §4 — the chronology executor: events in date order with their sources, a date the documents
//  disagree on shown both ways (never averaged), documents without a dated event listed as a
//  limitation, a case with no dated event blocked with its reason; and the job result store keeps
//  every run, the latest current.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Chronology executor and job results")
struct ChronologyExecutorTests {

    func day(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }

    @Test("Date order, disputed dates kept both ways, names linked, silent documents listed")
    func chronology() {
        let a = UUID(), b = UUID(), c = UUID()
        let ra = StudioEvidenceRef(sourceVersionID: UUID(), objectID: a, quote: "a"), rb = StudioEvidenceRef(sourceVersionID: UUID(), objectID: b, quote: "b")
        let facts = StudioCaseFacts(caseTitle: "Case", parties: [], dates: [], amounts: [], identifiers: [],
            documents: [StudioCaseDocument(objectID: a, sourceVersionID: nil, name: "memo.pdf", date: nil),
                        StudioCaseDocument(objectID: b, sourceVersionID: nil, name: "email.eml", date: nil),
                        StudioCaseDocument(objectID: c, sourceVersionID: nil, name: "photo.jpg", date: nil)],
            events: [StudioCaseEvent(date: day("2026-03-02"), title: "Payment approved by Asha Rao", refs: [ra]),
                     StudioCaseEvent(date: day("2026-03-01"), title: "Payment approved by Asha Rao", refs: [rb]),
                     StudioCaseEvent(date: day("2026-01-10"), title: "Contract signed", refs: [ra])],
            allFacts: [], named: [StudioCaseValue(value: "Asha Rao", label: "person", refs: [ra])], statedAmounts: [])
        let r = ChronologyExecutor.run(facts)
        #expect(r.state == .draft)
        #expect(r.content.rows.map(\.date) == ["2026-01-10", "2026-03-01", "2026-03-02"])
        #expect(r.content.rows.filter { $0.flags.contains("disputed date") }.count == 2)
        #expect(r.content.rows[1].detail == "Names: Asha Rao")
        #expect(r.content.rows.allSatisfy { !$0.refs.isEmpty })
        #expect(r.content.limitations.first?.contains("photo.jpg") == true)
        #expect(r.content.nextActions.contains { $0.contains("different dates") })
    }

    @Test("No dated event: blocked with the reason, never an empty success")
    func blocked() {
        let facts = StudioCaseFacts(caseTitle: "Case", parties: [], dates: [], amounts: [], identifiers: [], documents: [], events: [],
                                    allFacts: [], named: [], statedAmounts: [])
        let r = ChronologyExecutor.run(facts)
        #expect(r.state == .blocked && r.content.rows.isEmpty && !r.content.limitations.isEmpty)
    }

    @Test("A date a document states with no recognised event is a row titled by its sentence; relative dates never are")
    func statedDates() {
        let a = UUID(), b = UUID()
        let ra = StudioEvidenceRef(sourceVersionID: UUID(), objectID: a, quote: "q")
        let rb = StudioEvidenceRef(sourceVersionID: UUID(), objectID: b, quote: "q")
        let facts = StudioCaseFacts(caseTitle: "Case", parties: [], dates: [], amounts: [], identifiers: [],
            documents: [StudioCaseDocument(objectID: a, sourceVersionID: nil, name: "release.txt", date: nil),
                        StudioCaseDocument(objectID: b, sourceVersionID: nil, name: "letter.txt", date: nil)],
            events: [StudioCaseEvent(date: day("2009-03-03"), title: "Indictment returned", refs: [rb])],
            allFacts: [], named: [StudioCaseValue(value: "Clark Roberts", label: "person", refs: [ra])], statedAmounts: [],
            statedDates: [StudioCaseEvent(date: day("2007-05-28"), title: "In late May 2007 Clark Roberts visited the plant.", refs: [ra]),
                          // Same document and day as an event: the event stands, the bare date adds nothing.
                          StudioCaseEvent(date: day("2009-03-03"), title: "Returned on March 3, 2009.", refs: [rb])])
        let r = ChronologyExecutor.run(facts)
        #expect(r.state == .draft)
        #expect(r.content.rows.map(\.date) == ["2007-05-28", "2009-03-03"])
        #expect(r.content.rows[0].flags == ["date stated in text"] && r.content.rows[0].detail == "Names: Clark Roberts")
        #expect(r.content.rows[1].title == "Indictment returned")
        #expect(r.content.limitations.isEmpty, "both documents are in the chronology")
        #expect(r.content.nextActions.contains { $0.contains("only state a date") })
        // Only a date written with its year is a stated date.
        #expect(StudioCaseFactsReader.statedDay(raw: "March 3, 2009", normalized: "2009-03-03t06:30:00z") != nil)
        #expect(StudioCaseFactsReader.statedDay(raw: "today", normalized: "2026-10-28t06:30:00z") == nil)
        #expect(StudioCaseFactsReader.statedDay(raw: "this morning", normalized: "2026-10-28t03:30:00z") == nil)
    }

    @Test("Each run is kept; the latest is current, earlier ones superseded")
    func resultsKept() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = JobResultRepository(database: db)
        let caseID = UUID()
        // T1 — a result for a case that does not exist (or was erased) is not saved.
        await #expect(throws: JobResultError.caseGone) {
            try await repo.save(caseID: caseID, jobID: "inv.linkage", family: .chronologyLinkage, state: .draft,
                                content: JobResultContent(rows: []), actor: "Tester")
        }
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .uuid(UUID()), .text("Case"), .integer(1), .text("Tester"), .date(Date()), .date(Date())])
        let first = try await repo.save(caseID: caseID, jobID: "inv.linkage", family: .chronologyLinkage, state: .draft,
                                        content: JobResultContent(rows: [JobResultRow(title: "A", date: "2026-01-01")]), actor: "Tester")
        let second = try await repo.save(caseID: caseID, jobID: "inv.linkage", family: .chronologyLinkage, state: .draft,
                                         content: JobResultContent(rows: [JobResultRow(title: "B")]), actor: "Tester")
        #expect(try await repo.latest(caseID: caseID, jobID: "inv.linkage")?.id == second)
        let history = try await repo.history(caseID: caseID, jobID: "inv.linkage")
        #expect(history.map(\.id) == [second, first] && history.last?.state == .superseded)
        #expect(history.last?.content.rows.first?.title == "A")
        await #expect(throws: StudioRecordError.blankActor) {
            try await repo.save(caseID: caseID, jobID: "x", family: .chronologyLinkage, state: .draft, content: JobResultContent(rows: []), actor: " ")
        }
    }
}
