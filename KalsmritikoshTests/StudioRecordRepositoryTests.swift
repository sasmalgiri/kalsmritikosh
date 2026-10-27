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

    @Test("A draft is bound to one case; another case is refused; revisions and exports are frozen; removal keeps it")
    func bindingRevisionsExports() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = StudioRecordRepository(database: db)
        var m = SIUReferral(title: "Claim 1", now: t0)
        let id = m.id, caseA = UUID(), caseB = UUID()
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

    @Test("A name is required for every change")
    func actorRequired() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        await #expect(throws: StudioRecordError.blankActor) {
            try await StudioRecordRepository(database: db).save(studio: "siu", id: UUID(), title: "x", payload: Data("{}".utf8), actor: "  ")
        }
    }
}
