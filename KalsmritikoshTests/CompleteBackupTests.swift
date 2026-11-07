//
//  CompleteBackupTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §11: a complete backup carries the ledger AND the original files, with the
//  map that relinks them. Restored on another "Mac" (a fresh folder, the originals gone from their old
//  paths), every source the ledger names opens from the restored copy, byte for byte; what could not
//  be read is listed; a tampered original refuses the restore and leaves the target untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Complete backup and restore")
struct CompleteBackupTests {

    func scratch(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cbk-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("Originals travel with the ledger and are relinked on restore; unreadable ones are listed")
    func roundTrip() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let oldMac = try scratch("old")
        let letter = oldMac.appendingPathComponent("letter.txt"), memo = oldMac.appendingPathComponent("memo.txt")
        try Data("The approval letter.".utf8).write(to: letter)
        try Data("The internal memo.".utf8).write(to: memo)
        let letterID = UUID(), memoID = UUID()
        for (id, url) in [(letterID, letter), (memoID, memo)] {
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(id), .text(url.absoluteString), .text("txt"), .text("available")])
        }
        let snapshotDir = try scratch("snap")
        let snapshot = snapshotDir.appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snapshot)
        let backup = try scratch("backup")
        let manifest = try BackupService().createCompleteBackup(
            databaseSnapshot: snapshot, originals: [(letterID, letter), (memoID, memo)], notIncluded: ["/Volumes/Gone/scan.pdf"],
            destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        // One original could not be read, so the backup is NOT labelled complete (final brief §3.8).
        #expect(manifest.coverage == .ledgerWithSomeOriginals)
        #expect(try BackupService().inspect(backupFolder: backup).verdict.note.contains("Ledger with some originals"))
        #expect(manifest.entries.filter { $0.kind == .originalSource }.count == 2)
        #expect(try BackupService().inspect(backupFolder: backup).verdict.ok)

        // The old Mac is gone.
        try FileManager.default.removeItem(at: oldMac)
        let newMac = try scratch("new")
        let map = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        #expect(map.notIncluded == ["/Volumes/Gone/scan.pdf"])
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        for (id, text) in [(letterID, "The approval letter."), (memoID, "The internal memo.")] {
            let url = try #require(try await restored.query("SELECT url FROM files WHERE id = ?;", [.uuid(id)]).first?.string(0).flatMap(URL.init(string:)))
            #expect(url.path.hasPrefix(newMac.standardizedFileURL.path))
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
        await restored.close()
    }

    @Test("A restore chosen in Settings runs at the next launch, keeps the replaced ledger, and runs once")
    func scheduledAtBoot() async throws {
        defer { PendingRestore.cancel() }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let src = try scratch("psrc")
        let letter = src.appendingPathComponent("letter.txt")
        try Data("The approval letter.".utf8).write(to: letter)
        let id = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text(letter.absoluteString), .text("txt"), .text("available")])
        let snap = try scratch("psnap").appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = try scratch("pbackup")
        let full = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(id, letter)], notIncluded: [],
                                                 destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        #expect(full.coverage == .complete)   // nothing left out
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        #expect(PendingRestore.isScheduled)
        // This Mac's current ledger.
        let data = try scratch("pdata")
        let live = data.appendingPathComponent("knowledge.sqlite")
        try Data("the current ledger".utf8).write(to: live)
        // A plaintext (pre-encryption) backup restores whatever key this Mac holds — here a key that
        // never encrypted it, as on any Mac that already has an encrypted ledger.
        let outcome = await PendingRestore.performIfScheduled(databaseURL: live, recoveryKey: LedgerKey.random(), nowEpoch: 42)
        guard case .restored(let note) = outcome else { Issue.record("not restored: \(outcome)"); return }
        #expect(note.contains("1 original file(s)"))
        #expect(!PendingRestore.isScheduled)
        // The replaced ledger is kept, never deleted.
        #expect(try String(contentsOf: data.appendingPathComponent("Before restore 42/knowledge.sqlite"), encoding: .utf8) == "the current ledger")
        let restored = try Database(url: live)
        let url = try #require(try await restored.query("SELECT url FROM files WHERE id = ?;", [.uuid(id)]).first?.string(0).flatMap(URL.init(string:)))
        #expect(try String(contentsOf: url, encoding: .utf8) == "The approval letter.")
        await restored.close()
        // Nothing scheduled: boot does nothing.
        #expect(await PendingRestore.performIfScheduled(databaseURL: live, recoveryKey: nil) == .none)
        // A folder that is not a backup is not scheduled.
        #expect(PendingRestore.schedule(backupFolder: try scratch("empty")) != nil)
        #expect(!PendingRestore.isScheduled)
    }

    @Test("A tampered original refuses the restore and the target is left as it was")
    func tamperRefused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let src = try scratch("src")
        let letter = src.appendingPathComponent("letter.txt")
        try Data("Original bytes.".utf8).write(to: letter)
        let id = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text(letter.absoluteString), .text("txt"), .text("available")])
        let snap = try scratch("snap").appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = try scratch("backup")
        try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(id, letter)], notIncluded: [],
                                                 destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        try Data("Altered bytes!!".utf8).write(to: backup.appendingPathComponent("originals/letter.txt"))
        let target = try scratch("target")
        try Data("existing ledger".utf8).write(to: target.appendingPathComponent("knowledge.sqlite"))
        await #expect(throws: BackupService.BackupError.self) {
            try await BackupService().restoreComplete(backupFolder: backup, into: target, ledgerKey: nil)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("knowledge.sqlite"), encoding: .utf8) == "existing ledger")
    }
}

// MARK: - Living case map (v171)

extension CompleteBackupTests {

    @Test("Case map: saved views, positions with pins and investigator links travel in a complete backup and come back by identity on restore")
    func caseMapStateRoundTrip() async throws {
        let f = try await CaseFileTests.fixture()
        let repo = CaseMapRepository(database: f.db)
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        let caseNode = CaseMapNodeID(caseID: f.caseID, kind: .caseFile, id: f.caseID)
        let aNode = CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: allegation)
        let view = try await repo.saveView(caseID: f.caseID, name: "Payments", base: .questions, filter: CaseMapFilter(search: "invoice"), actor: "Ada")
        try await repo.savePlacements(caseID: f.caseID, [aNode: CaseMapPlacement(point: CaseMapPoint(x: 42, y: -7), pinned: true)])
        let link = try await repo.addLink(caseID: f.caseID, type: .dependsOn, from: caseNode, to: aNode, rationale: "the question rests on it", actor: "Ada")

        let snap = try scratch("mapsnap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = try scratch("mapbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        let newMac = try scratch("mapnew")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        let back = CaseMapRepository(database: restored)
        let views = try await back.views(caseID: f.caseID)
        #expect(views.map(\.id) == [view] && views.first?.name == "Payments" && views.first?.filter.search == "invoice" && views.first?.base == .questions)
        #expect(try await back.layout(caseID: f.caseID) == [aNode: CaseMapPlacement(point: CaseMapPoint(x: 42, y: -7), pinned: true)])
        let links = try await back.links(caseID: f.caseID)
        #expect(links.map(\.id) == [link] && links.first?.from == caseNode && links.first?.to == aNode && links.first?.rationale == "the question rests on it")
        await restored.close()
    }
}

// MARK: - Saved case searches (v172)

extension CompleteBackupTests {

    @MainActor
    @Test("Saved case searches travel in a complete backup and come back with their query, options and baseline")
    func savedCaseSearchRoundTrip() async throws {
        let f = try await CaseFileTests.fixture()
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "memo.txt", text: "The invoice was paid twice.")
        let service = CaseSearchService(sources: CaseSearchSources.live(database: f.db))
        let run = try #require(await service.run(caseID: f.caseID, text: "\"paid twice\"", options: CaseSearchOptions(timeZoneID: "UTC")).run)
        let id = try await service.save(run, name: "Twice", kind: .receipt, actor: "Ada")
        let snap = try scratch("searchsnap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = try scratch("searchbackup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        let newMac = try scratch("searchnew")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        let back = try #require(try await CaseSearchRepository(database: restored).savedSearch(id: id))
        #expect(back.kind == .receipt && back.query == run.query && back.options == run.options && back.indexRevision == run.indexRevision)
        #expect(back.result.matchedObjectIDs == run.hits.map(\.objectID) && back.result.documents == 1)
        await restored.close()
    }
}
