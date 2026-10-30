//
//  ACHRepositoryTests.swift
//  KalsmritikoshTests
//
//  A-6 — Competing hypotheses in the ledger (schema v152). Proves on a throwaway migrated database
//  in the temp directory: an analysis round-trips with its hypotheses, evidence, cells, assumptions,
//  indicators and conclusion, and its inconsistency scoring is unchanged; scope by case; removing a
//  hypothesis/evidence/analysis retracts (rows stay); an older save cannot roll a newer one back; the
//  AppStorage import runs once and keeps existing rows. Never touches the owner's ledger or Keychain.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("A-6 — ACH matrices in the ledger", .serialized)
struct ACHRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_100_000)

    private func repo() async throws -> (Database, ACHRepository) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        return (db, ACHRepository(database: db))
    }

    @Test("An analysis round-trips through the ledger with the same matrix and the same scores")
    func roundTrip() async throws {
        let (_, repo) = try await repo()
        let sample = ACHAnalysis.sample(now: t0)
        #expect(try await repo.save(sample, actor: "analyst", at: t0))
        let loaded = try #require(try await repo.analysis(id: sample.id))
        let a = loaded.analysis
        #expect(a.title == sample.title)
        #expect(a.question == sample.question)
        #expect(a.hypotheses == sample.hypotheses)
        #expect(a.evidence == sample.evidence)
        #expect(a.ratings == sample.ratings)
        #expect(a.assumptions == sample.assumptions)
        #expect(a.indicators == sample.indicators)
        #expect(a.conclusion == sample.conclusion)
        #expect(a.history == sample.history)
        #expect(a.createdAt == sample.createdAt)
        #expect(a.updatedAt == sample.updatedAt)
        #expect(loaded.createdBy == "analyst")
        #expect(loaded.importedFromDevice == false)
        // Scoring logic is untouched: identical scores, ranking and diagnosticity.
        for h in sample.hypotheses { #expect(a.inconsistencyScore(h) == sample.inconsistencyScore(h)) }
        #expect(a.leastInconsistent?.id == sample.leastInconsistent?.id)
        #expect(a.ranking.map(\.hypothesis.id) == sample.ranking.map(\.hypothesis.id))
        for e in sample.evidence { #expect(a.isDiagnostic(e) == sample.isDiagnostic(e)) }
    }

    @Test("Analyses are scoped by case; an unscoped list returns all live analyses")
    func scopedByCase() async throws {
        let (_, repo) = try await repo()
        let caseA = UUID(), caseB = UUID()
        let a = ACHAnalysis(title: "A", now: t0), b = ACHAnalysis(title: "B", now: t0), c = ACHAnalysis(title: "C", now: t0)
        try await repo.save(a, caseID: caseA, actor: "x", at: t0)
        try await repo.save(b, caseID: caseB, actor: "x", at: t0)
        try await repo.save(c, actor: "x", at: t0)
        #expect(try await repo.analyses(caseID: caseA).map(\.id) == [a.id])
        #expect(try await repo.analyses(caseID: caseA).first?.caseID == caseA)
        #expect(Set(try await repo.analyses().map(\.id)) == [a.id, b.id, c.id])
    }

    @Test("Removing a hypothesis, evidence row or the analysis retracts it — the rows stay in the ledger")
    func removalRetracts() async throws {
        let (db, repo) = try await repo()
        var a = ACHAnalysis.sample(now: t0)
        try await repo.save(a, actor: "analyst", at: t0)
        let gone = a.hypotheses[2], goneE = a.evidence[0]
        a.hypotheses.removeLast(); a.evidence.removeFirst()
        a.updatedAt = t0.addingTimeInterval(60)
        try await repo.save(a, actor: "reviewer", at: t0.addingTimeInterval(60))
        let loaded = try #require(try await repo.analysis(id: a.id)).analysis
        #expect(loaded.hypotheses.map(\.id) == a.hypotheses.map(\.id))
        #expect(loaded.evidence.map(\.id) == a.evidence.map(\.id))
        let h = try await db.query("SELECT retracted_by, retracted_at FROM ach_hypotheses WHERE id = ?;", [.uuid(gone.id)]).first
        #expect(h?.string(0) == "reviewer")
        #expect(h?.date(1) != nil)
        #expect(try await db.query("SELECT 1 FROM ach_evidence WHERE id = ? AND retracted_at IS NOT NULL;", [.uuid(goneE.id)]).count == 1)

        try await repo.retract(analysisID: a.id, actor: "reviewer", at: t0.addingTimeInterval(120))
        #expect(try await repo.analyses().isEmpty)
        #expect(try await repo.isRetracted(id: a.id))
        #expect(try await db.query("SELECT COUNT(*) FROM ach_cells WHERE analysis_id = ?;", [.uuid(a.id)]).first?.int(0) ?? 0 > 0)
        await #expect(throws: ACHRepositoryError.self) { try await repo.save(a, actor: "reviewer") }
    }

    @Test("An older save cannot roll back a newer one; a changed cell records who changed it")
    func staleSaveRefused() async throws {
        let (db, repo) = try await repo()
        var a = ACHAnalysis.sample(now: t0)
        try await repo.save(a, actor: "one", at: t0)
        let older = a
        let key = ACHAnalysis.key(a.evidence[0].id, a.hypotheses[0].id)
        a.ratings[key] = .veryInconsistent
        a.updatedAt = t0.addingTimeInterval(30)
        #expect(try await repo.save(a, actor: "two", at: t0.addingTimeInterval(30)))
        #expect(try await repo.save(older, actor: "one", at: t0.addingTimeInterval(40)) == false)
        let loaded = try #require(try await repo.analysis(id: a.id)).analysis
        #expect(loaded.ratings[key] == .veryInconsistent)
        let who = try await db.query("SELECT updated_by FROM ach_cells WHERE evidence_id = ? AND hypothesis_id = ?;",
                                     [.uuid(a.evidence[0].id), .uuid(a.hypotheses[0].id)]).first?.string(0)
        #expect(who == "two")
        await #expect(throws: ACHRepositoryError.self) { try await repo.save(a, actor: "  ") }
    }

    @Test("The old AppStorage store is imported once; existing ledger rows are kept")
    func legacyImportRunsOnce() async throws {
        let (_, repo) = try await repo()
        let kept = ACHAnalysis(title: "Already in the ledger", now: t0)
        try await repo.save(kept, actor: "x", at: t0)
        var renamed = kept; renamed.title = "Old device copy"
        let fresh = ACHAnalysis.sample(now: t0)
        // The view decodes the blob exactly like this.
        let blob = try JSONEncoder().encode([renamed, fresh])
        let decoded = try JSONDecoder().decode([ACHAnalysis].self, from: blob)
        #expect(try await repo.hasImportedLegacy() == false)
        #expect(try await repo.importLegacy(decoded, actor: "owner", at: t0) == 1)
        #expect(try await repo.hasImportedLegacy())
        #expect(try await repo.importLegacy(decoded, actor: "owner", at: t0) == 0)
        let all = try await repo.analyses()
        #expect(all.count == 2)
        #expect(all.first { $0.id == kept.id }?.analysis.title == "Already in the ledger")
        let imported = try #require(all.first { $0.id == fresh.id })
        #expect(imported.importedFromDevice)
        #expect(imported.analysis.ratings == fresh.ratings)
    }

    // MARK: Investigator workflow review 2026-10-30, I3 (schema v166)

    @Test("Unassessed and neutral survive save and reopen as different states; clearing a rating is recorded as 'unassessed' with who cleared it, and reads back as no rating")
    func unassessedAndNeutralPersistDistinctly() async throws {
        let (db, repo) = try await repo()
        var a = ACHAnalysis(title: "states", now: t0)
        let h1 = ACHHypothesis(text: "H1"), h2 = ACHHypothesis(text: "H2")
        a.hypotheses = [h1, h2]
        let e = ACHEvidence(text: "e")
        a.evidence = [e]
        let k1 = ACHAnalysis.key(e.id, h1.id), k2 = ACHAnalysis.key(e.id, h2.id)
        a.ratings[k1] = .neutral                        // explicit N; k2 left unassessed
        #expect(try await repo.save(a, actor: "one", at: t0))
        var loaded = try #require(try await repo.analysis(id: a.id)).analysis
        #expect(loaded.ratings[k1] == .neutral && loaded.ratings[k2] == nil)
        #expect(loaded.rating(e, h1) == .neutral && loaded.rating(e, h2) == nil)
        #expect(loaded.preference == .noDiscriminatingEvidence && loaded.leastInconsistent == nil)
        #expect(try await db.query("SELECT COUNT(*) FROM ach_cells WHERE analysis_id = ?;", [.uuid(a.id)]).first?.int(0) == 1, "an unassessed cell writes no row")

        // Rate k2, then clear k1: the clearing is a recorded state, not a deleted row.
        loaded.ratings[k2] = .inconsistent
        loaded.ratings[k1] = nil
        loaded.updatedAt = t0.addingTimeInterval(10)
        #expect(try await repo.save(loaded, actor: "two", at: t0.addingTimeInterval(10)))
        let again = try #require(try await repo.analysis(id: a.id)).analysis
        #expect(again.ratings[k1] == nil && again.ratings[k2] == .inconsistent)
        let cleared = try await db.query("SELECT consistency, updated_by FROM ach_cells WHERE evidence_id = ? AND hypothesis_id = ?;",
                                         [.uuid(e.id), .uuid(h1.id)]).first
        #expect(cleared?.string(0) == "unassessed" && cleared?.string(1) == "two")
        // The report tells the two states apart after the reopen.
        let md = ACHReportRenderer.markdown(again, generatedAt: t0)
        #expect(md.contains("| — | I |"))
        #expect(md.contains("1 of 2 cells rated; 1 unassessed"))
    }

    @Test("A structured citation round-trips; a row without one reads back as uncited")
    func citationRoundTrips() async throws {
        let (_, repo) = try await repo()
        var a = ACHAnalysis(title: "cite", now: t0)
        a.hypotheses = [ACHHypothesis(text: "H1"), ACHHypothesis(text: "H2")]
        let version = UUID()
        let cited = ACHEvidence(text: "debit", source: "p.2", citation: StudioEvidenceRef(sourceVersionID: version, quote: "Debit 10,000.00"))
        let note = ACHEvidence(text: "my recollection", source: "")
        a.evidence = [cited, note]
        #expect(try await repo.save(a, actor: "x", at: t0))
        let loaded = try #require(try await repo.analysis(id: a.id)).analysis
        #expect(loaded.evidence.count == 2)
        #expect(loaded.evidence[0].citation == StudioEvidenceRef(sourceVersionID: version, quote: "Debit 10,000.00") && loaded.evidence[0].isCited)
        #expect(loaded.evidence[1].citation == nil && !loaded.evidence[1].isCited)
        // Removing the citation persists too.
        var edited = loaded
        edited.evidence[0].citation = nil
        edited.updatedAt = t0.addingTimeInterval(5)
        #expect(try await repo.save(edited, actor: "x", at: t0.addingTimeInterval(5)))
        #expect(try #require(try await repo.analysis(id: a.id)).analysis.evidence[0].citation == nil)
    }

    @Test("Upgrading a v165 ledger keeps every stored cell and admits the 'unassessed' state")
    func v166CarriesCellsOver() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 165)
        let aid = UUID(), eid = UUID(), hid = UUID()
        try await db.exec("INSERT INTO ach_analyses (id, title, question, assumptions_json, indicators_json, confidence, conclusion_summary, history_json, origin, created_by, created_at, updated_by, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(aid), .text("old"), .text(""), .text("[]"), .text("[]"), .text("moderate"), .text(""), .text("[]"), .text("ledger"), .text("x"), .date(t0), .text("x"), .date(t0)])
        try await db.exec("INSERT INTO ach_hypotheses (id, analysis_id, position, text, created_by, created_at, updated_by, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(hid), .uuid(aid), .integer(0), .text("H1"), .text("x"), .date(t0), .text("x"), .date(t0)])
        try await db.exec("INSERT INTO ach_evidence (id, analysis_id, position, text, source, created_by, created_at, updated_by, updated_at) VALUES (?,?,?,?,?,?,?,?,?);",
                          [.uuid(eid), .uuid(aid), .integer(0), .text("e"), .text("note"), .text("x"), .date(t0), .text("x"), .date(t0)])
        try await db.exec("INSERT INTO ach_cells (analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(aid), .uuid(eid), .uuid(hid), .text("inconsistent"), .text("x"), .date(t0)])
        // The old CHECK refuses the new state.
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO ach_cells (analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at) VALUES (?,?,?,?,?,?);",
                              [.uuid(aid), .uuid(UUID()), .uuid(hid), .text("unassessed"), .text("x"), .date(t0)])
        }
        try await SchemaMigrations.migrate(db)
        let kept = try await db.query("SELECT consistency, updated_by FROM ach_cells WHERE evidence_id = ? AND hypothesis_id = ?;", [.uuid(eid), .uuid(hid)]).first
        #expect(kept?.string(0) == "inconsistent" && kept?.string(1) == "x")
        try await db.exec("INSERT INTO ach_cells (analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(aid), .uuid(UUID()), .uuid(hid), .text("unassessed"), .text("x"), .date(t0)])
        let loaded = try #require(try await ACHRepository(database: db).analysis(id: aid)).analysis
        #expect(loaded.evidence.first?.citation == nil && loaded.evidence.first?.source == "note")
        #expect(loaded.ratings[ACHAnalysis.key(eid, hid)] == .inconsistent)
    }
}

@Suite("A-9 — pair communication timeline")
struct PairCommunicationTimelineTests {

    @Test("Emails and events merge by date, undated last; an event read from the same email that day is not repeated")
    func mergeOrdersAndDedupes() {
        let ko = UUID()
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let email = PairTimelineItem(id: "email|1", kind: .email, date: d1.addingTimeInterval(3_600), title: "Invoice",
                                     detail: nil, fromFirst: true, sourceObjectID: ko)
        let sameEvent = PairTimelineItem(id: "event|1", kind: .event, date: d1, title: "Invoice sent",
                                         detail: nil, fromFirst: nil, sourceObjectID: ko)
        let earlier = PairTimelineItem(id: "event|2", kind: .event, date: d1.addingTimeInterval(-86_400 * 3), title: "Meeting",
                                       detail: nil, fromFirst: nil, sourceObjectID: UUID())
        let undated = PairTimelineItem(id: "email|2", kind: .email, date: nil, title: "Re:", detail: nil,
                                       fromFirst: false, sourceObjectID: UUID())
        let merged = PairTimeline.merge(emails: [undated, email], events: [sameEvent, earlier])
        #expect(merged.map(\.id) == ["event|2", "email|1", "email|2"])
    }

    @Test("An email's own Date header is read, with or without a trailing zone comment")
    func emailDates() {
        let a = PairTimeline.emailDate("Tue, 3 Mar 2020 10:15:00 +0000 (UTC)")
        let b = PairTimeline.emailDate("Tue, 3 Mar 2020 10:15:00 +0000")
        #expect(a != nil)
        #expect(a == b)
        #expect(PairTimeline.emailDate("not a date") == nil)
        #expect(PairTimeline.emailDate(nil) == nil)
    }
}
