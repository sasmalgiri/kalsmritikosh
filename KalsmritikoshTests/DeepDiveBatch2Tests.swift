//
//  DeepDiveBatch2Tests.swift
//  KalsmritikoshTests
//
//  Deep dive 2026-11-14 batch 2 (erasure, restore, sync integrity) — one regression test per confirmed defect
//  (docs/SMART_MAP_DEFECT_LOG.md, "Deep dive 2026-11-14 batch 2"). Synthetic ledgers in their own temporary folders; no
//  model, no network. No calendar dates are computed (time-zone free: only epoch seconds are compared).
//

import CryptoKit
import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - Helpers

/// A ledger of its own in a fresh folder (so plans and registers beside it are this test's only), with a workspace.
private struct DD2Ledger {
    let dir: URL
    let url: URL
    let db: Database
    let cases: InvestigationCaseRepository
    let workspaceID: UUID

    static func make(_ tag: String) async throws -> DD2Ledger {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("knowledge.sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: url)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        return DD2Ledger(dir: dir, url: url, db: db, cases: InvestigationCaseRepository(database: db), workspaceID: ws.id)
    }

    func newCase(_ title: String) async throws -> UUID {
        try await cases.createCase(workspaceID: workspaceID, title: title, actor: "Ada", at: Date()).id
    }

    /// A person entity (mentioned in a document of `caseID`), optionally a case person of `caseID`.
    func person(_ name: String, caseID: UUID, linked: Bool = true, aliases: [String] = []) async throws -> UUID {
        let doc = try await CaseFileTestSources.seedPassage(db, cases: cases, caseID: caseID, name: "\(UUID().uuidString).txt", text: "\(name) was called.")
        let entity = UUID()
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(entity), .text("person"), .text(name), .text(name.lowercased()), .uuid(doc.object)])
        for a in aliases {
            try await db.exec("INSERT INTO entity_aliases (entity_id, alias_normalized, source) VALUES (?,?,?);", [.uuid(entity), .text(a), .text("test")])
        }
        if linked {
            try await db.exec("INSERT INTO case_people (id, case_id, name, role, entity_id, created_at) VALUES (?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(caseID), .text(name), .text("witness"), .uuid(entity), .real(1)])
        }
        return entity
    }

    func revision(_ caseID: UUID, _ json: String) async throws -> UUID {
        let id = UUID()
        try await db.exec("INSERT INTO case_record_revisions (id, case_id, record_kind, record_id, change, after_json, actor, recorded_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(id), .uuid(caseID), .text("profile"), .text("x"), .text("profileSaved"), .text(json), .text("Ada"), .real(1)])
        return id
    }

    func count(_ sql: String, _ b: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    func remove() async {
        await db.close()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// One sync device over its own ledger (as SmartMapS18Tests does).
private struct DD2Device {
    let dir: URL
    let db: Database
    let engine: SyncEngine
    static func make(_ name: String, store: SyncStore) async throws -> DD2Device {
        let dir = try ParityFixture.tempFolder("dd2-dev-\(name)")
        let db = try await ParityFixture.database(in: dir)
        let intake = dir.appendingPathComponent("Intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let engine = SyncEngine(database: db, store: store, deviceID: "device-\(name)", deviceName: name, signingKey: Curve25519.Signing.PrivateKey(),
                                notes: NotesStore(base: dir), intakeFolder: intake,
                                saveIntake: { data, fileName, _ in
                                    let target = intake.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
                                    try data.write(to: target)
                                    return CaptureIntake.Saved(file: target, sha256: SyncCrypto.sha256Hex(data))
                                })
        return DD2Device(dir: dir, db: db, engine: engine)
    }
}

private func dd2Repo() -> URL { SmartMapS9Tests.repoRoot }

@Suite("Deep dive 2026-11-14 batch 2 — erasure, restore, sync integrity", .serialized)
struct DeepDiveBatch2Tests {

    // MARK: #1 — person erasure matched short aliases as substrings in every case

    @Test("#1: names match whole words only; an alias \"ed\" no longer touches another case's revisions, saved searches or sync values; an alias reaches only the person's cases; the full name still reaches every case")
    func personEraseWholeWordsAndScope() async throws {
        #expect(!CaseEraser.names(#"{"created_at":1}"#, ["ed"]))
        #expect(!CaseEraser.names("the allegation", ["al"]))
        #expect(!CaseEraser.names("Brian said", ["ian"]))
        #expect(CaseEraser.names("Call Ed. today", ["ed"]))
        #expect(CaseEraser.names("met zoe muller on Monday", ["Zoë Müller"]))
        #expect(CaseEraser.names("Zoe\u{0308} Mu\u{0308}ller (decomposed)", ["zoë müller"]))

        let l = try await DD2Ledger.make("p1")
        defer { Task { await l.remove() } }
        let theirs = try await l.newCase("Theirs"), other = try await l.newCase("Other")
        let entity = try await l.person("Edward Stone", caseID: theirs, aliases: ["ed", "eddie"])
        let otherCreated = try await l.revision(other, #"{"created_at":1,"note":"allegation filed"}"#)
        let otherAlias = try await l.revision(other, #"{"note":"Eddie called"}"#)
        let otherFull = try await l.revision(other, #"{"note":"Edward Stone approved"}"#)
        let theirsAlias = try await l.revision(theirs, #"{"note":"Eddie called"}"#)
        try await CaseErasureTests.seedSavedSearch(l.db, caseID: other, words: "created_at > 5")
        try await l.db.exec("INSERT INTO sync_pending (id, op_json, reason, first_seen) VALUES ('keep', '{\"fields\":{\"created_at\":\"1\"}}', 'document not here', 1);", [])
        try await l.db.exec("INSERT INTO sync_pending (id, op_json, reason, first_seen) VALUES ('gone', '{\"fields\":{\"note\":\"edward stone\"}}', 'document not here', 1);", [])

        let report = try await CaseEraser(database: l.db).erasePerson(entityID: entity, reason: "Subject request", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        func exists(_ id: UUID) async throws -> Bool { try await l.count("SELECT COUNT(*) FROM case_record_revisions WHERE id = ?;", [.uuid(id)]) == 1 }
        #expect(try await exists(otherCreated), "\"ed\" matched created_at in an unrelated case")
        #expect(try await exists(otherAlias), "an alias reaches only the person's own cases")
        #expect(!(try await exists(otherFull)), "the full name is erased in every case")
        #expect(!(try await exists(theirsAlias)), "an alias in the person's case is erased")
        #expect(try await CaseErasureTests.savedSearches(l.db, other) == 1)
        #expect(try await l.count("SELECT COUNT(*) FROM sync_pending WHERE id = 'keep';") == 1)
        #expect(try await l.count("SELECT COUNT(*) FROM sync_pending WHERE id = 'gone';") == 0)
    }

    // MARK: #2 — a restore that failed after the swap said "not changed" and left the work half done

    @Test("#2: a complete restore that fails after its files are swapped in is rolled back — the ledger, the register and the folder are as before; a good restore then merges the register and records the pause step")
    func restoreRollsBackAfterSwap() async throws {
        // The old Mac: a ledger with a marker and an erased case on its register.
        let old = try await DD2Ledger.make("rold")
        defer { Task { await old.remove() } }
        try await old.db.exec("UPDATE workspaces SET title = 'FROM-THE-BACKUP';", [])
        let erasedCase = UUID(), erasedPerson = UUID()
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(erasedCase), eraseSources: false, erasedAt: 5), besideLedgerAt: old.url)
        let snapDir = old.dir.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await old.db.backupSnapshot(to: snap)
        let backup = old.dir.appendingPathComponent("backup", isDirectory: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 10, besideLedger: old.dir)
        // This Mac: its own ledger and register.
        let mac = try await DD2Ledger.make("rmac")
        try await mac.db.exec("UPDATE workspaces SET title = 'CURRENT';", [])
        try ErasureRegister.record(.init(kind: .person, idHash: ErasureRegister.hash(erasedPerson), eraseSources: nil, erasedAt: 7), besideLedgerAt: mac.url)
        await mac.db.close()
        defer { try? FileManager.default.removeItem(at: mac.dir) }
        let registerBefore = try Data(contentsOf: ErasureRegister.url(besideLedgerAt: mac.url))
        let ledgerBefore = try Data(contentsOf: mac.url)

        await #expect(throws: (any Error).self) {
            _ = try await BackupService(failAfterSwap: true).restoreComplete(backupFolder: backup, into: mac.dir, ledgerKey: nil)
        }
        #expect(try Data(contentsOf: mac.url) == ledgerBefore, "the ledger is the one it was")
        #expect(try Data(contentsOf: ErasureRegister.url(besideLedgerAt: mac.url)) == registerBefore, "the register merge was undone")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: mac.dir.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.hasPrefix(".\(mac.dir.lastPathComponent).previous-") }, "nothing left aside")
        #expect(!FileManager.default.fileExists(atPath: mac.dir.appendingPathComponent(BackupService.sourcesMapName).path))
        let reopened = try Database(url: mac.url)
        #expect(try await reopened.query("SELECT title FROM workspaces;", []).first?.string(0) == "CURRENT")
        #expect(try await reopened.query("SELECT COUNT(*) FROM ledger_restores;", []).first?.int(0) == 0)
        await reopened.close()

        // The same restore without the failure: kept, register merged, the pause step recorded.
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: mac.dir, ledgerKey: nil)
        let merged = try ErasureRegister.load(besideLedgerAt: mac.url)
        #expect(ErasureRegister.matches([erasedCase], kind: .case, in: merged).count == 1)
        #expect(ErasureRegister.matches([erasedPerson], kind: .person, in: merged).count == 1)
        let restored = try Database(url: mac.url)
        #expect(try await restored.query("SELECT title FROM workspaces;", []).first?.string(0) == "FROM-THE-BACKUP")
        #expect(try await restored.query("SELECT COUNT(*) FROM ledger_restores;", []).first?.int(0) == 1)
        await restored.close()
    }

    // MARK: #3 — merge chains

    @Test("#3: a person erasure follows a merge chain C → B → A (bounded), so the entities merged into a merged entity go too")
    func personEraseFollowsMergeChain() async throws {
        let l = try await DD2Ledger.make("p3")
        defer { Task { await l.remove() } }
        let c = try await l.newCase("Case")
        let a = try await l.person("Meera Iyer", caseID: c)
        let ko = try #require(try await l.db.query("SELECT source_object_id FROM entities WHERE id = ?;", [.uuid(a)]).first?.string(0))
        let b = UUID(), cc = UUID(), stranger = UUID()
        for (id, into, label) in [(b, a, "M. Iyer"), (cc, b, "Meera I."), (stranger, nil as UUID?, "Bo Chen")] {
            try await l.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, merged_into) VALUES (?,?,?,?,?,?);",
                                [.uuid(id), .text("person"), .text(label), .text(label.lowercased()), .text(ko), into.map { .uuid($0) } ?? .null])
        }
        try await l.db.exec("INSERT INTO entity_aliases (entity_id, alias_normalized, source) VALUES (?,?,?);", [.uuid(cc), .text("meera i"), .text("test")])
        let report = try await CaseEraser(database: l.db).erasePerson(entityID: a, reason: "Subject request", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await l.count("SELECT COUNT(*) FROM entities WHERE id IN (?,?,?);", [.uuid(a), .uuid(b), .uuid(cc)]) == 0, "C (merged into B) went with A")
        #expect(try await l.count("SELECT COUNT(*) FROM entity_aliases WHERE entity_id = ?;", [.uuid(cc)]) == 0)
        #expect(try await l.count("SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(stranger)]) == 1, "an unrelated entity stays")
    }

    // MARK: #4 — a crash between the ledger commit and the register write

    @Test("#4: a case or person erasure that committed but crashed before its register write is added to the register at the next launch; a plan for a person still in the ledger is dropped")
    func resumeWritesTheRegister() async throws {
        let l = try await DD2Ledger.make("p4")
        defer { Task { await l.remove() } }
        let gone = try await l.newCase("Erased")
        let entity = try await l.person("Ann Lee", caseID: gone, linked: false)
        let stays = try await l.person("Bo Chen", caseID: gone, linked: false)
        // The plans as the app writes them before it erases (AppState.eraseCase / erasePerson).
        try AppState.writeCaseEraseRecord(AppState.caseEraseRecordURL(besideLedgerAt: l.url, caseID: gone), vault: [], dropVectorCache: false,
                                          register: .init(erasedAt: 42, eraseSources: false))
        try AppState.writePersonEraseRecord(AppState.personEraseRecordURL(besideLedgerAt: l.url, entityID: entity), erasedAt: 43)
        try AppState.writePersonEraseRecord(AppState.personEraseRecordURL(besideLedgerAt: l.url, entityID: stays), erasedAt: 44)
        // The erasures commit; the process dies before the register is written.
        let eraser = CaseEraser(database: l.db)
        #expect(try await eraser.erase(caseID: gone, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Ada").refused == nil)
        #expect(try await eraser.erasePerson(entityID: entity, reason: "Subject request", legalBasis: nil, actor: "Ada").refused == nil)
        #expect(try ErasureRegister.load(besideLedgerAt: l.url).entries.isEmpty)
        // Next launch.
        let pending = await AppState.resumePendingCaseErasures(besideLedgerAt: l.url, database: l.db)
        #expect(pending.isEmpty, "\(pending)")
        let register = try ErasureRegister.load(besideLedgerAt: l.url)
        let caseEntry = try #require(ErasureRegister.matches([gone], kind: .case, in: register).first)
        #expect(caseEntry.entry.erasedAt == 42)
        #expect(ErasureRegister.matches([entity], kind: .person, in: register).first?.entry.erasedAt == 43)
        #expect(ErasureRegister.matches([stays], kind: .person, in: register).isEmpty, "a person still in the ledger was never erased")
        let left = try FileManager.default.contentsOfDirectory(atPath: l.dir.path).filter { $0.hasPrefix(".case-erase-") || $0.hasPrefix(".person-erase-") }
        #expect(left.isEmpty, "\(left)")
    }

    // MARK: #5 — "Before restore" copies were not in the list of backups

    @Test("#5: the copy a restore keeps is listed with this Mac's backups (an erasure names it) and \"Delete backups made before this erasure\" removes it only while it is that copy")
    func beforeRestoreCopiesListed() async throws {
        defer { PendingRestore.cancel() }
        let old = try await DD2Ledger.make("bold")
        defer { Task { await old.remove() } }
        let snapDir = old.dir.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await old.db.backupSnapshot(to: snap)
        let backup = old.dir.appendingPathComponent("backup", isDirectory: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 10, besideLedger: old.dir)
        let mac = try await DD2Ledger.make("bmac")
        await mac.db.close()
        defer { try? FileManager.default.removeItem(at: mac.dir) }
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        guard case .restored = await PendingRestore.performIfScheduled(databaseURL: mac.url, recoveryKey: nil, nowEpoch: 1000) else {
            Issue.record("not restored"); return
        }
        let listed = try BackupLog.madeBefore(2000, besideLedgerAt: mac.url)
        let kept = try #require(listed.first { $0.kind == .beforeRestore })
        #expect(kept.name == "Before restore 1000" && kept.createdAt == 1000)
        #expect(AppState.backupsBefore(2000, besideLedgerAt: mac.url).entries.contains { $0.kind == .beforeRestore })
        // A folder that is no longer that copy (its ledger changed size; a look-alike without a marker) is kept.
        let lookalike = mac.dir.appendingPathComponent("Before restore 900", isDirectory: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lookalike.appendingPathComponent("knowledge.sqlite"))
        _ = BackupLog.record(folder: lookalike, kind: .beforeRestore, createdAt: 900, besideLedgerAt: mac.url)
        let keptURL = URL(fileURLWithPath: kept.path, isDirectory: true)
        #expect(BackupLog.isRecordedBackup(keptURL, entry: kept))
        let result = BackupLog.deleteBackups(madeBefore: 2000, besideLedgerAt: mac.url)
        #expect(result.deleted.map(\.name) == ["Before restore 1000"], "\(result.summary)")
        #expect(!FileManager.default.fileExists(atPath: keptURL.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path) && result.kept.contains { $0.contains("no longer that backup") })
    }

    // MARK: #6 — a relocated ledger: erasures only beside one copy

    @Test("#6: an erasure made on one copy of a moved ledger is applied when the other copy opens (register mirrored, or adopted at open); the receipt names the other copy; the backup lists of both copies are read")
    func otherLedgerCopyFollowsErasures() async throws {
        let disk = try await DD2Ledger.make("disk")
        defer { Task { await disk.remove() } }
        let caseX = try await disk.newCase("Matter X")
        let person = try await disk.person("Meera Iyer", caseID: caseX, linked: false)
        // The copy on this Mac: the same ledger.
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("dd2-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        let localURL = localDir.appendingPathComponent("knowledge.sqlite")
        try await disk.db.backupSnapshot(to: localURL)
        // Which copy is "the other one".
        #expect(LedgerRelocation.otherCopies(of: disk.url, local: localURL, relocatedFolder: disk.dir) == [localURL])
        #expect(LedgerRelocation.otherCopies(of: localURL, local: localURL, relocatedFolder: disk.dir) == [disk.url])
        #expect(LedgerRelocation.otherCopies(of: localURL, local: localURL, relocatedFolder: nil).isEmpty)

        // The case is erased on the disk copy; the register is mirrored beside this Mac's copy.
        let eraser = CaseEraser(database: disk.db)
        #expect(try await eraser.erase(caseID: caseX, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Ada").refused == nil)
        #expect(ErasureRegister.recordReporting(.init(kind: .case, idHash: ErasureRegister.hash(caseX), eraseSources: false, erasedAt: 50),
                                                besideLedgerAt: disk.url, otherCopies: [localURL]) == nil)
        // The person is erased on the disk copy while this Mac's copy was out of reach (register beside the disk copy only).
        #expect(try await eraser.erasePerson(entityID: person, reason: "Subject request", legalBasis: nil, actor: "Ada").refused == nil)
        #expect(ErasureRegister.recordReporting(.init(kind: .person, idHash: ErasureRegister.hash(person), eraseSources: nil, erasedAt: 60),
                                                besideLedgerAt: disk.url) == nil)
        // This Mac's copy opens (disk connected): both come back erased.
        let local = try Database(url: localURL)
        defer { Task { await local.close() } }
        #expect(try await local.query("SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(caseX)]).first?.int(0) == 1)
        let pass = await AppState.reapplyErasureRegister(database: local, otherCopies: [disk.url])
        #expect(pass.erased == 2 && pass.problems.isEmpty, "\(pass)")
        #expect(try await local.query("SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(caseX)]).first?.int(0) == 0)
        #expect(try await local.query("SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(person)]).first?.int(0) == 0)
        #expect(ErasureRegister.matches([person], kind: .person, in: try ErasureRegister.load(besideLedgerAt: localURL)).count == 1,
                "this Mac's copy keeps the adopted entry")
        // The receipt names the other copy, plainly.
        let report = CaseErasureReport(erasureID: UUID(), refused: nil, rowsErased: ["investigation_cases": 1], sourcesErased: 0, sourcesKeptShared: 0,
                                       sourcesKeptInLibrary: 0, documentsStillNaming: 0, vaultAddresses: [])
        let outcome = AppState.ErasureOutcome(report: report, fileResidue: [], otherLedgerCopies: [localDir.path])
        #expect(outcome.summary.contains("Another copy of this ledger is kept at \(localDir.path)"))
        // Backups listed beside either copy are named once.
        let b = localDir.appendingPathComponent("b1", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = BackupLog.record(folder: b, kind: .ledger, createdAt: 30, besideLedgerAt: localURL)
        #expect(try BackupLog.madeBefore(100, besideLedgerAt: disk.url).isEmpty)
        #expect(try BackupLog.madeBefore(100, besideLedgerAt: disk.url, otherCopies: [localURL]).map(\.name) == ["b1"])
    }

    // MARK: #7 — sync redaction cursor advanced past an unreadable batch

    @Test("#7: a batch of this Mac's that cannot be read during redaction is retried at the next sync (the cursor does not pass it)")
    func unreadableBatchRetried() async throws {
        let root = try ParityFixture.tempFolder("dd2-sync")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        let a = try await DD2Device.make("A", store: store)
        defer { for u in [root, a.dir] { try? FileManager.default.removeItem(at: u) } }
        let doc = try await ParityFixture.document(a.db, name: "lease.txt", text: "Lease between Ada and Bo.", fileHash: "filehash-dd2").id
        let gone = try await AnnotationsRepository(database: a.db).add(objectID: doc, sourceURL: nil, quote: "Lease", note: "Informant: Meera Iyer")
        #expect(try await a.engine.sync().batchesWritten == 1)
        let erasure = UUID()
        try await a.db.withSavepoint("dd2_erase") { db in
            _ = try ErasureGenerations.begin(db, kind: "person", scopeHash: ErasureGenerations.scopeHash(erasure), erasureID: erasure, at: Date())
            try db.exec("DELETE FROM annotations WHERE id = ?;", [.uuid(gone)])
            try ErasureGenerations.finish(db, erasureID: erasure)
        }
        // The batch is unreadable for this sync (a damaged or half-copied file in the folder).
        let seq = try #require(store.batchNumbers(of: "device-A").first)
        let file = root.appendingPathComponent(SyncFormat.logFolder).appendingPathComponent("device-A").appendingPathComponent(SyncFormat.batchName(seq))
        let good = try Data(contentsOf: file)
        try Data("damaged".utf8).write(to: file)
        #expect(try await a.engine.sync().batchesRedacted == 0)
        // Readable again: the next sync still redacts it.
        try good.write(to: file)
        #expect(try await a.engine.sync().batchesRedacted == 1, "the unreadable batch was skipped for good")
        let ops = try store.readBatch(device: "device-A", seq: seq).ops
        #expect(!ops.contains { $0.fields.values.contains { $0.display.contains("Meera") } })
    }

    // MARK: #8 — the register pass stopped at the first failure

    @Test("#8: one register entry that fails is reported and the others are still erased again")
    func registerPassContinuesPastAFailure() async throws {
        let l = try await DD2Ledger.make("p8")
        defer { Task { await l.remove() } }
        let c1 = try await l.newCase("One"), c2 = try await l.newCase("Two")
        let person = try await l.person("Ann Lee", caseID: c1, linked: false)
        for (kind, id) in [(ErasureRegister.Kind.case, c1), (.case, c2), (.person, person)] {
            try ErasureRegister.record(.init(kind: kind, idHash: ErasureRegister.hash(id), eraseSources: false, erasedAt: 1), besideLedgerAt: l.url)
        }
        // A principal without a grant: reading each case fails (thrown), the person's erasure does not depend on it.
        let pass = await CaseAccessContext.$principal.withValue(.local("Mallory")) {
            await AppState.reapplyErasureRegister(database: l.db)
        }
        #expect(pass.problems.count == 2, "\(pass)")
        #expect(pass.erased == 1)
        #expect(try await l.count("SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(person)]) == 0, "the person after the failing cases was erased again")
    }

    // MARK: #9 — an old plan's vault list dropped after a restore

    @Test("#9: at open the register pass runs before the resume step, and the vault copies an unfinished plan listed are joined into the re-erasure")
    func oldPlanVaultJoined() async throws {
        let l = try await DD2Ledger.make("p9")
        defer { Task { await l.remove() } }
        let x = try await l.newCase("Came back")
        let vault = EvidenceVault(root: l.dir.appendingPathComponent("EvidenceVault", isDirectory: true))
        let orphan = try await vault.store(Data("an erased document's copy".utf8))
        #expect(await vault.contains(orphan))
        // The first erasure left its plan (the copy not yet removed); a restored backup brought the case back.
        try AppState.writeCaseEraseRecord(AppState.caseEraseRecordURL(besideLedgerAt: l.url, caseID: x), vault: [orphan], dropVectorCache: false)
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(x), eraseSources: false, erasedAt: 1), besideLedgerAt: l.url)
        // Boot order: register pass, then resume.
        let pass = await AppState.reapplyErasureRegister(database: l.db)
        #expect(pass.erased == 1, "\(pass)")
        _ = await AppState.resumePendingCaseErasures(besideLedgerAt: l.url, database: l.db)
        #expect(!(await vault.contains(orphan)), "the old plan's copy was dropped")
        let src = try String(contentsOf: dd2Repo().appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)
        let reapply = try #require(src.range(of: "registerPassAtOpen = await Self.reapplyErasureRegister"))
        let resume = try #require(src.range(of: "pendingErasureWork = await Self.resumePendingCaseErasures"))
        #expect(reapply.lowerBound < resume.lowerBound)
    }

    // MARK: #10 — timestamps

    @Test("#10: a backup's time is taken before its snapshot, and an erasure's time is the date the ledger records for it")
    func timestampsTakenFirst() throws {
        for file in ["Kalsmritikosh/UI/SettingsView.swift", "Kalsmritikosh/UI/MoveToNewMacView.swift"] {
            let src = try String(contentsOf: dd2Repo().appendingPathComponent(file), encoding: .utf8)
            #expect(!src.contains("nowEpoch: Date().timeIntervalSince1970"), "\(file) stamps a backup after its snapshot")
            var rest = src[...]
            while let snap = rest.range(of: "database.backupSnapshot(to: snapshot)") {
                let before = src[..<snap.lowerBound].suffix(600)
                #expect(before.contains("let backupStartedAt = Date().timeIntervalSince1970"), "\(file)")
                rest = src[snap.upperBound...]
            }
        }
        let erasure = try String(contentsOf: dd2Repo().appendingPathComponent("Kalsmritikosh/App/AppState+Erasure.swift"), encoding: .utf8)
        #expect(erasure.contains("legalBasis: legalBasis, actor: actor, at: erasedDate)"))
        #expect(erasure.contains("reason: reason, legalBasis: legalBasis, actor: actor, at: erasedDate)"))
        #expect(!erasure.contains("let erasedAt = Date().timeIntervalSince1970\n        if let left = ErasureRegister"))
    }

    // MARK: #11 — count-back checks that could never find leftovers

    @Test("#11: a child row of a case table, or a row derived from an erased document, that survives its delete is now found by the count-back and the erase is rolled back")
    func countBackFindsLeftovers() async throws {
        let l = try await DD2Ledger.make("p11")
        defer { Task { await l.remove() } }
        let c = try await l.newCase("Case")
        let allegation = UUID()
        try await l.db.exec("INSERT INTO case_allegations (id, case_id, sequence, text, created_at) VALUES (?,?,1,'Shouting',1);", [.uuid(allegation), .uuid(c)])
        try await l.db.exec("INSERT INTO case_allegation_evidence (id, allegation_id, evidence_ref, stance, added_by, created_at) VALUES (?,?,'ref','supports','Ada',1);",
                            [.uuid(UUID()), .uuid(allegation)])
        try await l.db.exec("CREATE TEMP TRIGGER dd2_keep_evidence BEFORE DELETE ON case_allegation_evidence BEGIN SELECT RAISE(IGNORE); END;", [])
        let eraser = CaseEraser(database: l.db)
        let refused = try await eraser.erase(caseID: c, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Ada")
        #expect(refused.refused?.contains("case_allegation_evidence") == true, "\(refused.refused ?? "erased with a child row left")")
        #expect(try await l.count("SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(c)]) == 1, "rolled back")
        try await l.db.exec("DROP TRIGGER dd2_keep_evidence;", [])

        // A row derived from the case's own document (by version) that survives its delete.
        let doc = try await CaseFileTestSources.seedPassage(l.db, cases: l.cases, caseID: c, name: "only.txt", text: "Only this case uses it.")
        try await l.db.exec("CREATE TABLE dd2_derived (id TEXT PRIMARY KEY, source_version_id TEXT);", [])
        try await l.db.exec("INSERT INTO dd2_derived (id, source_version_id) VALUES ('d1', ?);", [.uuid(doc.version)])
        try await l.db.exec("CREATE TEMP TRIGGER dd2_keep_derived BEFORE DELETE ON dd2_derived BEGIN SELECT RAISE(IGNORE); END;", [])
        let again = try await eraser.erase(caseID: c, sourceVersionIDs: [doc.version], eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Ada")
        #expect(again.refused?.contains("dd2_derived") == true, "\(again.refused ?? "erased with a derived row left")")
        #expect(try await l.count("SELECT COUNT(*) FROM source_versions WHERE id = ?;", [.uuid(doc.version)]) == 1, "rolled back")
        try await l.db.exec("DROP TRIGGER dd2_keep_derived;", [])
        // Without the stuck rows the erase completes.
        let done = try await eraser.erase(caseID: c, sourceVersionIDs: [doc.version], eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Ada")
        #expect(done.refused == nil && done.sourcesErased == 1, "\(done.refused ?? "")")
    }

    // MARK: #12 — shared-document check compared source_ref as exact text

    @Test("#12: a document another case names by its id in another letter case is shared: kept, not erased with the case")
    func sharedCheckIgnoresLetterCase() async throws {
        let l = try await DD2Ledger.make("p12")
        defer { Task { await l.remove() } }
        let a = try await l.newCase("A"), b = try await l.newCase("B")
        let doc = try await CaseFileTestSources.seedPassage(l.db, cases: l.cases, caseID: a, name: "shared.txt", text: "Both cases use it.")
        let logical = try #require(try await l.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(doc.version)]).first?.string(0))
        try await l.db.exec("""
            INSERT INTO investigation_case_sources (id, case_id, source_ref, source_kind, in_scope, note, created_at) VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(b), .text(logical.lowercased()), .text("logicalSource"), .integer(1), .null, .real(1)])
        let out = try await CaseEraser(database: l.db).erase(caseID: a, sourceVersionIDs: [doc.version], eraseExclusiveSources: true,
                                                             reason: "Client request", legalBasis: nil, actor: "Ada")
        #expect(out.refused == nil, "\(out.refused ?? "")")
        #expect(out.sourcesKeptShared == 1 && out.sourcesErased == 0)
        #expect(try await l.count("SELECT COUNT(*) FROM files WHERE id = ?;", [.text(logical)]) == 1, "case B's document was erased")
    }
}
