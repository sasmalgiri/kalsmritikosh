//
//  StudioRecordRepositoryTests.swift
//  KalsmritikoshTests
//
//  Final brief §3.1 / §19 "Studio migration": studio work lives in the encrypted ledger, bound to
//  its case. The old preference store migrates once (a retry does not duplicate); a corrupt record is
//  quarantined byte for byte, never dropped; revisions and export snapshots are frozen; a draft cannot
//  be re-pointed to another case; removing a draft keeps it in the record.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Studio records in the ledger")
struct StudioRecordRepositoryTests {

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A real workspace and case (review R3: tests bind to cases that exist).
    func makeCase(_ db: Database, status: String = "open", workspace: UUID = UUID()) async throws -> (caseID: UUID, workspaceID: UUID) {
        let c = UUID()
        try await db.exec("INSERT OR IGNORE INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(workspace), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(c), .uuid(workspace), .text("C"), .text(status), .integer(1), .text("u"), .real(1), .real(1)])
        return (c, workspace)
    }

    func legacyElement(_ data: Data) -> StudioLegacyElement? {
        guard let m = try? JSONDecoder().decode(SIUReferral.self, from: data) else { return nil }
        return StudioLegacyElement(id: m.id, title: m.title, updatedAt: m.updatedAt)
    }

    @Test("The old store imports once; a corrupt record is quarantined; the import verifies before the copy may go")
    func legacyImport() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        let a = SIUReferral.sample(now: t0), b = SIUReferral(title: "Second claim", now: t0)
        let good = String(decoding: try JSONEncoder().encode([a, b]), as: UTF8.self)
        // A third element that is not an SIU referral at all.
        let blob = String(good.dropLast()) + #",{"broken":true}]"#
        let r = try await repo.importLegacy(studio: "siu", sourceKey: "k.siu", blob: blob, actor: "Tester", at: t0, decode: legacyElement)
        #expect(Set(r.importedIDs) == [a.id, b.id])
        #expect(r.quarantined == 1)
        let q = try await repo.quarantined(sourceKey: "k.siu")
        #expect(q.count == 1 && q[0].raw.contains("broken"))
        #expect(try await repo.verifyImported(r.importedIDs) { (try? JSONDecoder().decode(SIUReferral.self, from: $0)) != nil })
        // Retry: nothing duplicated.
        let again = try await repo.importLegacy(studio: "siu", sourceKey: "k.siu", blob: blob, actor: "Tester", at: t0, decode: legacyElement)
        #expect(again.alreadyImported && again.importedIDs.isEmpty)
        let rows = try await repo.records(studio: "siu")
        #expect(rows.count == 2 && rows.allSatisfy { $0.importedFromDevice && $0.caseID == nil })
        // The imported payload decodes to the same model.
        let back = try JSONDecoder().decode(SIUReferral.self, from: try #require(rows.first { $0.id == a.id }).payload)
        #expect(back == a)
        // A store that is not JSON at all is quarantined whole.
        let bad = try await repo.importLegacy(studio: "siu", sourceKey: "k.bad", blob: "{not json", actor: "Tester", at: t0, decode: legacyElement)
        #expect(bad.importedIDs.isEmpty && bad.quarantined == 1)
    }

    @Test("Review R4: the exact original store is kept; every element has an outcome; same-id conflicts are quarantined, never skipped")
    func legacyCollisions() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        let a = SIUReferral(title: "Claim A", now: t0)
        var a2 = a; a2.claimNumber = "DIFFERENT"          // same id, different content
        let b = SIUReferral(title: "Claim B", now: t0)
        var bLedger = b; bLedger.claimNumber = "LEDGER"   // the ledger already holds b's id with other content
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try await repo.save(studio: "siu", id: b.id, title: b.title, payload: try enc.encode(bLedger), actor: "Tester", at: t0)
        let c = SIUReferral(title: "Claim C", now: t0)
        try await repo.save(studio: "siu", id: c.id, title: c.title, payload: try enc.encode(c), actor: "Tester", at: t0)
        let list = [a, a, a2, b, c]                       // identical duplicate, conflicting duplicate, ledger conflict, already migrated
        let body = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        let blob = "  \n" + body + "\n "                   // whitespace that a re-encoding would lose
        let r = try await repo.importLegacy(studio: "siu", sourceKey: "k.col", blob: blob, actor: "Tester", at: t0, decode: legacyElement)
        #expect(r.importedIDs == [a.id])
        #expect(r.elementCount == 5 && r.everyElementAccounted)
        let outcomes = try await repo.legacyOutcomes(sourceKey: "k.col").map(\.outcome)
        #expect(outcomes == ["imported", "identicalDuplicate", "quarantined", "quarantined", "alreadyMigrated"])
        // The conflicting versions are preserved, not lost.
        let q = try await repo.quarantined(sourceKey: "k.col")
        #expect(q.count == 2 && q[0].raw.contains("DIFFERENT") && q[1].error.contains("ledger holds a different record"))
        // The ledger's own record was not overwritten.
        let held = try JSONDecoder().decode(SIUReferral.self, from: try #require(try await repo.record(id: b.id)).payload)
        #expect(held.claimNumber == "LEDGER")
        // The exact original text, whitespace and all, with a matching digest.
        let kept = try #require(try await repo.legacyBlob(sourceKey: "k.col"))
        #expect(kept.raw == blob && kept.intact)
        // The kept copy cannot be rewritten.
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE studio_legacy_blobs SET raw_blob = 'x';", []) }
        // A store that is not valid JSON is kept exactly, untrimmed.
        let broken = "  {not json  "
        let rb = try await repo.importLegacy(studio: "siu", sourceKey: "k.broken", blob: broken, actor: "Tester", at: t0, decode: legacyElement)
        #expect(rb.everyElementAccounted && rb.quarantined == 1)
        #expect(try await repo.legacyBlob(sourceKey: "k.broken")?.raw == broken)
    }

    @Test("A draft is bound to one case; another case is refused; revisions and exports are frozen; removal keeps it")
    func bindingRevisionsExports() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        var m = SIUReferral(title: "Claim 1", now: t0)
        let id = m.id
        let caseA = try await makeCase(db).caseID, caseB = try await makeCase(db).caseID
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try await repo.save(studio: "siu", id: id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0)
        try await repo.bind(recordID: id, caseID: caseA, workspaceID: nil, actor: "Tester", at: t0)
        await #expect(throws: StudioRecordError.boundToAnotherCase(caseA)) {
            try await repo.bind(recordID: id, caseID: caseB, workspaceID: nil, actor: "Tester", at: t0)
        }
        // Saving it under another case is refused too.
        await #expect(throws: StudioRecordError.boundToAnotherCase(caseA)) {
            try await repo.save(studio: "siu", id: id, title: "x", payload: Data("{}".utf8), caseID: caseB, actor: "Tester", at: t0)
        }
        #expect(try await repo.records(studio: "siu", caseID: caseA).map(\.id) == [id])
        #expect(try await repo.records(studio: "siu", caseID: caseB).isEmpty)
        // Edits within the interval update the head; a later edit cuts a revision.
        m.claimNumber = "CLM-1"
        try await repo.save(studio: "siu", id: id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0.addingTimeInterval(10))
        m.claimNumber = "CLM-2"
        try await repo.save(studio: "siu", id: id, title: m.title, payload: try enc.encode(m), actor: "Tester",
                            at: t0.addingTimeInterval(StudioRecordRepository.revisionInterval + 20))
        let revs = try await repo.revisions(recordID: id)
        #expect(revs.map(\.reason).first == "created")
        #expect(revs.contains { $0.reason.hasPrefix("bound to case") })
        // An export freezes the text and the revision it came from.
        let ex = try await repo.recordExport(recordID: id, format: "markdown", text: "# Report v1", actor: "Tester", at: t0.addingTimeInterval(400))
        #expect(ex.artifactSHA256 == StudioRecordRepository.sha256(Data("# Report v1".utf8)))
        let frozen = try #require(try await repo.payload(recordID: id, revision: ex.revision))
        #expect(try JSONDecoder().decode(SIUReferral.self, from: frozen).claimNumber == "CLM-2")
        // Later edits do not change the exported snapshot or its revision.
        m.claimNumber = "CLM-3"
        try await repo.save(studio: "siu", id: id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0.addingTimeInterval(1_000))
        #expect(try await repo.exports(recordID: id).first?.snapshot == "# Report v1")
        #expect(try JSONDecoder().decode(SIUReferral.self, from: try #require(try await repo.payload(recordID: id, revision: ex.revision))).claimNumber == "CLM-2")
        // History cannot be rewritten.
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE studio_record_exports SET snapshot_text = 'changed';", [])
        }
        await #expect(throws: (any Error).self) {
            try await db.exec("DELETE FROM studio_record_revisions;", [])
        }
        // Removal retracts: gone from the list, still readable.
        try await repo.retract(recordID: id, actor: "Tester", at: t0.addingTimeInterval(2_000))
        #expect(try await repo.records(studio: "siu").isEmpty)
        #expect(try await repo.record(id: id) != nil)
        await #expect(throws: StudioRecordError.retracted(id)) {
            try await repo.save(studio: "siu", id: id, title: "x", payload: Data("{}".utf8), actor: "Tester", at: t0)
        }
    }

    @Test("Review R5: a failed save stays pending and is sent by Retry without another edit; a failed removal is retried; a backup flush refuses while unsaved")
    @MainActor
    func failedSaveRetried() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        let storage = StudioStorage(studio: "siu", legacyKey: "test.r5.\(UUID().uuidString)")
        storage.repositoryOverride = repo
        struct Down: Error {}
        storage.writeFault = { throw Down() }
        let m = SIUReferral(title: "Claim R5", now: t0)
        storage.persist([m], app: nil)
        await storage.flush()
        #expect(storage.hasUnsavedChanges && storage.pendingCount == 1)
        #expect(try await repo.record(id: m.id) == nil)
        #expect(await StudioStorage.flushAll() == false)          // a backup now would miss it
        // The fault clears; Retry sends the same unchanged content.
        storage.writeFault = nil
        storage.retry(app: nil)
        await storage.flush()
        #expect(!storage.hasUnsavedChanges && storage.pendingCount == 0 && storage.problem == nil)
        #expect(try await repo.record(id: m.id) != nil)
        // A failed removal is not forgotten either.
        storage.writeFault = { throw Down() }
        storage.persist([SIUReferral](), app: nil)
        await storage.flush()
        #expect(storage.hasUnsavedChanges)
        #expect(try await repo.records(studio: "siu").map(\.id) == [m.id])
        storage.writeFault = nil
        storage.retry(app: nil)
        await storage.flush()
        #expect(try await repo.records(studio: "siu").isEmpty)
        #expect(await StudioStorage.flushAll())
    }

    @Test("Review R3: the parent case must exist, be in the stated workspace and be open to edit; missing drafts fail; approval is bound to the approved content")
    func parentCaseAndApproval() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var m = SIUReferral(title: "Claim R3", now: t0)
        try await repo.save(studio: "siu", id: m.id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0)
        // A case that does not exist; a case in another workspace.
        await #expect(throws: StudioRecordError.caseNotFound(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)) {
            try await repo.bind(recordID: m.id, caseID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, workspaceID: nil, actor: "Tester")
        }
        let (open, ws) = try await makeCase(db)
        await #expect(throws: StudioRecordError.caseInAnotherWorkspace(open)) {
            try await repo.bind(recordID: m.id, caseID: open, workspaceID: UUID(), actor: "Tester")
        }
        try await repo.bind(recordID: m.id, caseID: open, workspaceID: ws, actor: "Tester")
        // A missing draft fails explicitly.
        let ghost = UUID()
        await #expect(throws: StudioRecordError.notFound(ghost)) { try await repo.setReviewState(recordID: ghost, .approved, actor: "Tester") }
        await #expect(throws: StudioRecordError.notFound(ghost)) { try await repo.recordExport(recordID: ghost, format: "md", text: "x", actor: "Tester") }
        // Approval covers exactly the approved content: an edit within the revision interval makes it stale.
        try await repo.setReviewState(recordID: m.id, .approved, actor: "Reviewer", at: t0.addingTimeInterval(5))
        #expect(try await repo.approvalIsCurrent(recordID: m.id))
        m.claimNumber = "EDITED"
        try await repo.save(studio: "siu", id: m.id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0.addingTimeInterval(10))
        #expect(try await repo.approvalIsCurrent(recordID: m.id) == false)
        #expect(try await repo.record(id: m.id)?.reviewState == .draft)
        #expect(try await repo.revisions(recordID: m.id).contains { $0.reason.hasPrefix("approval no longer applies") })
        // A closed case: its draft can no longer be edited, but it can still be exported.
        try await db.exec("UPDATE investigation_cases SET status = 'closed' WHERE id = ?;", [.uuid(open)])
        m.claimNumber = "AFTER CLOSE"
        await #expect(throws: StudioRecordError.caseClosed(open)) {
            try await repo.save(studio: "siu", id: m.id, title: m.title, payload: try enc.encode(m), actor: "Tester", at: t0.addingTimeInterval(20))
        }
        let ex = try await repo.recordExport(recordID: m.id, format: "md", text: "historical", actor: "Tester", at: t0.addingTimeInterval(30))
        #expect(ex.snapshot == "historical")
        // Binding a new draft to the closed case is refused too.
        let n = SIUReferral(title: "New", now: t0)
        try await repo.save(studio: "siu", id: n.id, title: n.title, payload: try enc.encode(n), actor: "Tester", at: t0)
        await #expect(throws: StudioRecordError.caseClosed(open)) { try await repo.bind(recordID: n.id, caseID: open, workspaceID: ws, actor: "Tester") }
    }

    @Test("A name is required for every change")
    func actorRequired() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        await #expect(throws: StudioRecordError.blankActor) {
            try await StudioRecordRepository(database: db).save(studio: "siu", id: UUID(), title: "x", payload: Data("{}".utf8), actor: "  ")
        }
    }

    @Test("Review R2: one package — the recorded snapshot is the written file's bytes; an edit after validation exports nothing; a mismatched file is not recorded; DRAFT unless the approval is current")
    @MainActor
    func frozenExportPackage() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        let storage = StudioStorage(studio: "siu", legacyKey: "test.r2.\(UUID().uuidString)")
        storage.repositoryOverride = repo
        var m = SIUReferral(title: "Claim R2", now: t0)
        storage.persist([m], app: nil)
        await storage.flush()
        let render: (Bool) -> String = { approved in (approved ? "" : StudioStorage.draftBanner) + "Report for \(m.title)" }

        // Not approved → the one rendering carries the DRAFT banner.
        let draft = try #require(await storage.package(m, app: nil, render: render))
        #expect(!draft.approved && draft.text.hasPrefix(StudioStorage.draftBanner))

        // The written file is read back; the recorded snapshot is exactly its bytes, against the frozen revision.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r2-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(draft.text.utf8).write(to: url)
        storage.exported(draft, format: "markdown", writtenTo: url, app: nil)
        await storage.flush()
        var exports = try await repo.exports(recordID: m.id)
        #expect(exports.count == 1)
        #expect(exports.first?.artifactSHA256 == StudioRecordRepository.sha256(try Data(contentsOf: url)))
        #expect(exports.first?.snapshot == draft.text && exports.first?.revision == draft.revision)

        // A file that does not hold the package's bytes is not recorded.
        try Data("tampered".utf8).write(to: url)
        storage.exported(draft, format: "markdown", writtenTo: url, app: nil)
        await storage.flush()
        exports = try await repo.exports(recordID: m.id)
        #expect(exports.count == 1 && storage.problem?.contains("does not match") == true)
        storage.problem = nil

        // A cancelled print (or any action that did not complete) never calls exported → nothing recorded.
        _ = try #require(await storage.package(m, app: nil, render: render))
        #expect(try await repo.exports(recordID: m.id).count == 1)

        // The screen moved on after validation: the validated (stale) value exports nothing and is not written back.
        let validated = m
        m.title = "Claim R2 — edited"
        storage.persist([m], app: nil)
        await storage.flush()
        #expect(await storage.package(validated, app: nil, render: render) == nil)
        #expect(try await repo.record(id: m.id)?.title == "Claim R2 — edited")
        storage.problem = nil

        // Approved for exactly this content → no banner; any change → DRAFT again.
        try await repo.setReviewState(recordID: m.id, .approved, actor: "Tester")
        let final = try #require(await storage.package(m, app: nil, render: render))
        #expect(final.approved && !final.text.contains("DRAFT"))
        m.title = "Claim R2 — after approval"
        storage.persist([m], app: nil)
        await storage.flush()
        let again = try #require(await storage.package(m, app: nil, render: render))
        #expect(!again.approved && again.text.hasPrefix(StudioStorage.draftBanner))
        #expect(try await repo.approvalIsCurrent(recordID: m.id) == false)
    }

}
