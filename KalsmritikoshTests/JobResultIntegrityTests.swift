//
//  JobResultIntegrityTests.swift
//  KalsmritikoshTests
//
//  Completion instructions 2026-10-29, B2 — a job result goes through the same integrity rules as
//  the studios: typed fields parse (a nonempty but invalid date, amount or currency does not
//  complete); a value the person changed is kept apart from what the source stated and needs a
//  reason; a hand-added row prints as the reviewer's entry; the expected revision and the case's
//  open state are checked inside the write (simultaneous reviews, a stale restore, a case closed
//  during the save); completion and export re-check every cited source; an export is authorised
//  after the destination is chosen, rendered once, read back and recorded with its digest.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Job result integrity (B2)", .serialized)
struct JobResultIntegrityTests {

    @Test("Typed fields: an impossible date, a vague amount or an invented currency does not complete")
    func typedValidation() {
        #expect(JobFields.invalidReason(.date, "2026-02-30") != nil)
        #expect(JobFields.invalidReason(.date, "5 March") != nil)
        #expect(JobFields.invalidReason(.date, "2024-02-29") == nil)
        #expect(JobFields.invalidReason(.amount, "about 5k") != nil)
        #expect(JobFields.invalidReason(.amount, "1,250.00") == nil)
        #expect(JobFields.invalidReason(.currency, "XYZ") != nil)
        #expect(JobFields.invalidReason(.currency, "dollars") != nil)
        #expect(JobFields.invalidReason(.currency, "inr") == nil)
        var row = JobResultRow(title: "Transfer", decision: .accepted,
                               fields: ["from": "A-1", "to": "B-2", "date": "2026-13-01", "amount": "lots", "currency": "ZZZ", "method": "direct",
                                        "classification": "payment", "duplicates": "none found", "reconciled": "statement balance"])
        let bad = Set(JobFields.missing(job: "fa.funds-tracing", row: row).map(\.key))
        #expect(bad == ["date", "amount", "currency"])
        row.fields = ["from": "A-1", "to": "B-2", "date": "2026-01-05", "amount": "9,000.00", "currency": "USD", "method": "direct",
                      "classification": "payment", "duplicates": "none found", "reconciled": "statement balance"]
        #expect(JobFields.missing(job: "fa.funds-tracing", row: row).isEmpty)
        // An optional field, when given, must be valid too.
        let doc = JobResultRow(title: "Passport", decision: .accepted,
                               fields: ["document": "Passport", "versionDate": "2025-01-01", "current": "yes", "expiry": "soon"])
        #expect(JobFields.missing(job: "ind.document-versions", row: doc).map(\.key) == ["expiry"])
    }

    struct Ready {
        let f: CaseErasureTests.Fixture
        let repo: JobResultRepository
        let job: String
        let record: JobResultRecord
    }

    static func ready() async throws -> Ready {
        let f = try await CaseErasureTests.boot()
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        let service = try #require(await f.state.personaJobs)
        let job = try #require(PersonaJobCatalogComposer.allJobs.first { $0.id == "inv.source-reliability" })
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        _ = try await service.launch(job, context: PersonaJobLaunchContext(caseID: f.caseA, access: access, actor: "Tester", at: Date()))
        let repo = JobResultRepository(database: f.db)
        let record = try #require(try await repo.latest(caseID: f.caseA, jobID: job.id))
        #expect(!record.content.rows.isEmpty && record.content.rows.allSatisfy { $0.sourced?["title"] == $0.title },
                "a generated result freezes what its rows took from the ledger")
        return Ready(f: f, repo: repo, job: job.id, record: record)
    }

    /// Every row accepted, with every required field filled validly by the reviewer.
    static func decided(_ r: Ready) -> [JobResultRow] {
        r.record.content.rows.map { row in
            var row = row; row.decision = .accepted
            var d = row.fields ?? [:]
            for f in JobFields.specs[r.job] ?? [] where f.required && (d[f.key] ?? "").isEmpty {
                d[f.key] = JobFamilyExecutorTests.personValue(f)
            }
            row.fields = d
            return row
        }
    }

    static func privilege(_ r: Ready) async throws {
        let version = try #require(r.record.content.rows.flatMap(\.refs).compactMap(\.sourceVersionID).first)
        _ = try await SensitiveScopeRepository(database: r.f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Tester", confirmationID: UUID(), privileged: true), reason: "privileged")
    }

    @Test("A changed source value needs a reason and prints as the reviewer's entry beside what the source said; a hand-added row is the reviewer's")
    func editedValuesKeptApart() async throws {
        let r = try await Self.ready()
        defer { try? FileManager.default.removeItem(at: r.f.temp) }
        var rows = Self.decided(r)
        let said = rows[0].title
        rows[0].title = "Reliable — confirmed by phone"
        var manual = JobResultRow(title: "Witness statement not yet ingested", decision: .accepted)
        manual.manual = true
        for f in JobFields.specs[r.job] ?? [] where f.required { var d = manual.fields ?? [:]; d[f.key] = JobFamilyExecutorTests.personValue(f); manual.fields = d }
        rows.append(manual)
        await #expect(throws: JobResultReviewError.correctionNeedsReason(row: 0)) {
            try await r.repo.saveReview(of: r.record, rows: rows, complete: true, note: "Reviewed", actor: "Reviewer")
        }
        rows[0].note = "Called the source on 2026-06-02"
        try await r.repo.saveReview(of: r.record, rows: rows, complete: true, note: "Reviewed", actor: "Reviewer")
        let done = try #require(try await r.repo.latest(caseID: r.f.caseA, jobID: r.job))
        #expect(done.state == .completed)
        #expect(done.content.rows[0].assertions?.contains("title") == true && done.content.rows[0].sourced?["title"] == said)
        #expect(done.content.rows.last?.assertions?.contains("title") == true)
        let md = JobResultMarkdown.render(done, title: "Reliability")
        #expect(md.contains("Reliable — confirmed by phone [reviewer's entry]") && md.contains("The source-derived text was: \(said)"))
        #expect(md.contains("Added by the reviewer (no source linked — unproven)"))
        #expect(md.contains("version ") && md.contains("object "), "exported sources carry their exact identifiers")
    }

    @Test("Simultaneous reviews: the second, based on a revision no longer current, is refused; a stale restore is refused")
    func staleRevisionsRefused() async throws {
        let r = try await Self.ready()
        defer { try? FileManager.default.removeItem(at: r.f.temp) }
        let rows = Self.decided(r)
        let repo = r.repo, base = r.record
        let a = Task { try await repo.saveReview(of: base, rows: rows, complete: false, note: nil, actor: "Reviewer A") }
        let b = Task { try await repo.saveReview(of: base, rows: rows, complete: false, note: nil, actor: "Reviewer B") }
        let outcomes = [await a.result, await b.result]
        #expect(outcomes.filter { if case .success = $0 { return true }; return false }.count == 1, "exactly one of two concurrent reviews lands")
        #expect(outcomes.contains { if case .failure(let e) = $0 { return (e as? JobResultReviewError) == .notCurrent }; return false })
        // A restore based on what the person saw as current, after someone else saved, is refused.
        let history = try await r.repo.history(caseID: r.f.caseA, jobID: r.job)
        let original = try #require(history.last)
        await #expect(throws: JobResultReviewError.notCurrent) {
            try await r.repo.restore(original, over: original.id, actor: "Reviewer A")
        }
        #expect(try await r.repo.history(caseID: r.f.caseA, jobID: r.job).count == history.count, "nothing was written")
    }

    @Test("A case closed before the save lands refuses the review; the result is unchanged")
    func closedCaseRefuses() async throws {
        let r = try await Self.ready()
        defer { try? FileManager.default.removeItem(at: r.f.temp) }
        try await r.f.db.exec("UPDATE investigation_cases SET status = 'closed' WHERE id = ?;", [.uuid(r.f.caseA)])
        await #expect(throws: JobResultReviewError.caseClosed) {
            try await r.repo.saveReview(of: r.record, rows: Self.decided(r), complete: true, note: "Reviewed", actor: "Reviewer")
        }
        #expect(try await r.repo.latest(caseID: r.f.caseA, jobID: r.job)?.id == r.record.id)
    }

    @Test("Completion re-checks cited sources: a source made privileged since the run refuses completion")
    func completionRechecksEvidence() async throws {
        let r = try await Self.ready()
        defer { try? FileManager.default.removeItem(at: r.f.temp) }
        let check = await r.f.state.jobResultEvidenceCheck(caseID: r.f.caseA)
        try await Self.privilege(r)
        do {
            try await r.repo.saveReview(of: r.record, rows: Self.decided(r), complete: true, note: "Reviewed", actor: "Reviewer", evidenceCheck: check)
            Issue.record("completion must refuse a withdrawn source")
        } catch let e as JobResultReviewError {
            if case .unresolvedEvidence(let n) = e { #expect(n >= 1) } else { Issue.record("unexpected \(e)") }
        }
        // Rejecting the rows that cite it is an honest, valid completion.
        let rejected = Self.decided(r).map { row -> JobResultRow in var row = row; row.decision = .rejected; return row }
        try await r.repo.saveReview(of: r.record, rows: rejected, complete: true, note: "Sources withdrawn; nothing to rely on", actor: "Reviewer", evidenceCheck: check)
        #expect(try await r.repo.latest(caseID: r.f.caseA, jobID: r.job)?.state == .completed)
    }

    @Test("Export after the destination is chosen: a source privileged meanwhile writes nothing; a clean export records the written bytes")
    func exportAuthorisedAtWrite() async throws {
        let r = try await Self.ready()
        defer { try? FileManager.default.removeItem(at: r.f.temp) }
        let url = r.f.temp.appendingPathComponent("result.md")
        // The clean export: written, read back and recorded with the same digest.
        let receipt = try await r.f.state.exportJobResult(r.record, title: "Reliability", to: url, actor: "Tester")
        let bytes = try Data(contentsOf: url)
        #expect(StudioRecordRepository.sha256(bytes) == receipt.fileSHA256)
        let recorded = try await r.repo.exports(caseID: r.f.caseA)
        #expect(recorded.count == 1 && recorded[0].fileSHA256 == receipt.fileSHA256 && recorded[0].text == String(decoding: bytes, as: UTF8.self))
        await #expect(throws: (any Error).self) { try await r.f.db.exec("UPDATE job_result_exports SET file_sha256 = 'x';", []) }
        // A file that does not hold the exported text is not recorded.
        let other = r.f.temp.appendingPathComponent("tampered.md")
        try Data("different".utf8).write(to: other)
        await #expect(throws: JobResultExportError.writtenBytesDiffer) {
            _ = try await r.repo.recordExport(resultID: r.record.id, caseID: r.f.caseA, jobID: r.job, text: "the text", file: other, actor: "Tester")
        }
        // The dialog was open while a cited source became privileged: the write-time check refuses.
        try await Self.privilege(r)
        let late = r.f.temp.appendingPathComponent("late.md")
        await #expect(throws: JobResultExportError.self) {
            _ = try await r.f.state.exportJobResult(r.record, title: "Reliability", to: late, actor: "Tester")
        }
        #expect(!FileManager.default.fileExists(atPath: late.path), "nothing was written")
        #expect(try await r.repo.exports(caseID: r.f.caseA).count == 1)
        // A revision that is no longer current is not exported.
        try await r.repo.saveReview(of: r.record, rows: r.record.content.rows, complete: false, note: nil, actor: "Reviewer")
        await #expect(throws: JobResultReviewError.notCurrent) {
            _ = try await r.f.state.exportJobResult(r.record, title: "Reliability", to: late, actor: "Tester")
        }
    }
}
