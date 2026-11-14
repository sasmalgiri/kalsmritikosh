//
//  SEC07ErasureReachTests.swift
//  KalsmritikoshTests
//
//  SEC-07 (2026-11-13) — the local places an erasure could not reach before:
//   (a) backups made before an erasure: a restored one is reconciled (the register is applied again when the ledger
//       opens, before any worker reads it) for case AND person erasure, table by table; the receipt says earlier
//       backups still hold the data and names the ones this Mac made; deleting them is an explicit choice only;
//   (b) exports already written outside the app: listed (path, date, digest) from the output door's log, never deleted;
//   (c) the Keychain: no item is case-scoped; erasure leaves the ledger key; a full erase keeps it (existing behaviour);
//   (d) other cases' references to an erased case read "erased case" with no title or wording.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEC-07 erasure reach: backups, exports, Keychain, other cases' references", .serialized)
struct SEC07ErasureReachTests {

    static func count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    /// A person entity mentioned in the fixture's documents, linked as a case person of case B.
    static func person(_ f: CaseErasureTests.Fixture) async throws -> (id: UUID, name: String) {
        let row = try #require(try await f.db.query("""
            SELECT e.id, e.value FROM entities e WHERE e.merged_into IS NULL AND EXISTS (SELECT 1 FROM entity_mentions m WHERE m.entity_id = e.id)
            ORDER BY e.value LIMIT 1;
            """, []).first)
        let id = try #require(row.uuid(0)), name = try #require(row.string(1))
        let file = try #require(await f.state.caseFiles).file
        _ = try await file.addPerson(caseID: f.caseB, name: name, role: .witness, entityID: id, contact: nil, notes: nil, actor: "Tester")
        return (id, name)
    }

    static func tables(_ db: Database) async throws -> [String] {
        try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '%\\_fts%' ESCAPE '\\';", [])
            .compactMap { $0.string(0) }.filter { !CaseEraser.keptTables.contains($0) }
    }

    static func rowsJSON(_ db: Database, scope: String) async throws -> [String: Int] {
        let raw = try #require(try await db.query("SELECT rows_json FROM case_erasures WHERE scope = ? ORDER BY erased_at DESC LIMIT 1;", [.text(scope)]).first?.string(0))
        return try JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))
    }

    // MARK: (a) backups

    @Test("(a) backup → erase case and person → restore: re-erased at open in every table, counts equal the first erasure; receipt names earlier backups; deleting them is explicit")
    func backupsReconciledOnRestore() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let p = try await Self.person(f)
        let ledger = f.temp.appendingPathComponent("case.sqlite")
        // 1. A complete backup, recorded in this Mac's list of backups.
        let originals = try await f.db.query("SELECT id, url FROM files;", []).compactMap { r -> (fileID: UUID, url: URL)? in
            guard let id = r.uuid(0), let u = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return (id, u)
        }
        let snapDir = f.temp.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = f.temp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let manifest = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: originals, notIncluded: [], destination: backup,
                                                                schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970 - 60)
        #expect(await f.state.recordBackup(folder: backup, kind: .complete, createdAt: manifest.createdAtEpoch) == nil)
        // 2. Erase case A (with its own document) and the person.
        let caseOut = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(caseOut.report.refused == nil, "\(caseOut.report.refused ?? "")")
        let personOut = try await f.state.erasePerson(p.id, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(personOut.report.refused == nil, "\(personOut.report.refused ?? "")")
        for out in [caseOut, personOut] {
            #expect(out.backupsBefore.map(\.name) == ["backup"], "the backup made before is named")
            #expect(out.summary.contains("Backups made before this erasure still hold what was erased"))
            #expect(out.summary.contains("“backup”") && out.summary.contains(backup.path))
            #expect(out.summary.contains("nothing is deleted unless you choose it"))
        }
        #expect(FileManager.default.fileExists(atPath: backup.path), "the erasure itself deletes no backup")
        let firstCase = try await Self.rowsJSON(f.db, scope: "case")
        let firstPerson = try await Self.rowsJSON(f.db, scope: "person")
        // 3. Restore the older backup beside this Mac's register; open it.
        let mac = f.temp.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let restoredLedger = mac.appendingPathComponent("knowledge.sqlite")
        try FileManager.default.copyItem(at: ErasureRegister.url(besideLedgerAt: ledger), to: ErasureRegister.url(besideLedgerAt: restoredLedger))
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: mac)
        let state2 = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state2.boot(databaseURL: restoredLedger)
        guard case .ready = await state2.phase, let db2 = await state2.database else { Issue.record("the restored ledger did not open"); return }
        defer { Task { await db2.close() } }
        let notice = await state2.restoreNotice ?? "nil"
        #expect(notice.contains("2 case(s) or person(s) you had erased came back with a restored backup and were erased again"), "\(notice)")
        // Every table: nothing of case A by case_id, nothing of the person by an entity column.
        let entityColumns = ["entity_id", "canonical_entity_id", "entity_a", "entity_b"]
        for t in try await Self.tables(db2) {
            let cols = try await db2.query("PRAGMA table_info(\"\(t)\");", []).compactMap { $0.string(1) }
            if cols.contains("case_id") {
                #expect(try await Self.count(db2, "SELECT COUNT(*) FROM \"\(t)\" WHERE upper(case_id) = upper(?);", [.uuid(f.caseA)]) == 0, "\(t) kept case A")
            }
            for c in entityColumns where cols.contains(c) {
                #expect(try await Self.count(db2, "SELECT COUNT(*) FROM \"\(t)\" WHERE upper(\"\(c)\") = upper(?);", [.uuid(p.id)]) == 0, "\(t).\(c) kept the person")
            }
        }
        #expect(try await Self.count(db2, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(p.id)]) == 0)
        #expect(try await Self.count(db2, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        // The re-erasure removed exactly what the first erasure removed, table by table.
        let againCase = try await Self.rowsJSON(db2, scope: "case")
        let againPerson = try await Self.rowsJSON(db2, scope: "person")
        #expect(againCase == firstCase, "case: first \(firstCase) vs again \(againCase)")
        #expect(againPerson == firstPerson, "person: first \(firstPerson) vs again \(againPerson)")
        let again = await state2.applyErasureRegister()
        #expect(again == nil, "opening again changes nothing more")
        // 4. Deleting the earlier backups is an explicit choice: only the recorded backup, only while it is that backup.
        let reused = f.temp.appendingPathComponent("reused", isDirectory: true)
        try FileManager.default.createDirectory(at: reused, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: reused.appendingPathComponent("unrelated.txt"))
        _ = BackupLog.record(folder: reused, kind: .ledger, createdAt: manifest.createdAtEpoch - 10, besideLedgerAt: ledger)
        let later = f.temp.appendingPathComponent("later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        _ = BackupLog.record(folder: later, kind: .ledger, createdAt: caseOut.erasedAt + 100, besideLedgerAt: ledger)
        let result = await f.state.deleteBackups(madeBefore: caseOut.erasedAt)
        #expect(result.deleted.map(\.name) == ["backup"] && !FileManager.default.fileExists(atPath: backup.path))
        #expect(result.kept.count == 1 && result.kept[0].contains("no longer that backup") && FileManager.default.fileExists(atPath: reused.path))
        #expect(FileManager.default.fileExists(atPath: later.path), "a backup made after the erasure is not touched")
        #expect(try BackupLog.madeBefore(caseOut.erasedAt, besideLedgerAt: ledger).map(\.name) == ["reused"], "the deleted backup is marked")
        // An unreadable list is never "no backups".
        try Data("{nope".utf8).write(to: BackupLog.url(besideLedgerAt: ledger))
        #expect(AppState.backupsBefore(Date().timeIntervalSince1970, besideLedgerAt: ledger).problem?.contains("could not be read") == true)
        #expect(BackupLog.deleteBackups(madeBefore: Date().timeIntervalSince1970, besideLedgerAt: ledger).deleted.isEmpty)
    }

    // MARK: (b) exports

    @Test("(b) the erasure report lists the case's and the person's recorded exports with path, date and digest; the files are not deleted")
    func exportsListedNotDeleted() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let p = try await Self.person(f)
        let outputs = try #require(await f.state.caseOutputs)
        let outside = f.temp.appendingPathComponent("Outside folder", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func export(_ caseID: UUID, _ name: String) async throws -> (url: URL, digest: String) {
            let pkg = try await outputs.prepareText(caseID: caseID, kind: .achReport, route: .file, actor: "Tester", citations: [], text: "Report \(name)")
            let url = outside.appendingPathComponent(name)
            #expect(await outputs.write(pkg, to: url).status == .written)
            return (url, pkg.digest)
        }
        let a = try await export(f.caseA, "case-a-report.md")
        let b = try await export(f.caseB, "case-b-report.md")
        // A job result of case A saved to a file earlier (its own export record: file name and digest, no folder).
        try await f.db.exec("""
            INSERT INTO job_result_exports (id, result_id, case_id, job_id, result_sha256, file_name, file_sha256, snapshot_text, exported_by, exported_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(UUID()), .uuid(f.caseA), .text("job"), .text("r"), .text("job-result.csv"), .text("abc123"),
                  .text("snapshot"), .text("Tester"), .real(Date().timeIntervalSince1970 - 3600)])
        let caseOut = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(caseOut.report.refused == nil)
        #expect(caseOut.report.exportsOutside.count == 2)
        let job = try #require(caseOut.report.exportsOutside.first, "oldest first")
        #expect(job.fileName == "job-result.csv" && job.sha256 == "abc123" && job.route == "job result file" && job.path == nil)
        #expect(job.line.contains("job-result.csv") && job.line.contains("the folder was not recorded"))
        let listed = try #require(caseOut.report.exportsOutside.last)
        #expect(listed.path == a.url.standardizedFileURL.path && listed.sha256 == a.digest && listed.route == "file")
        #expect(listed.line.contains(a.url.standardizedFileURL.path) && listed.line.contains(String(a.digest.prefix(16))))
        #expect(listed.line.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2} \S+"#, options: .regularExpression) != nil, "a date with its zone")
        #expect(caseOut.summary.contains("outside the app and not erased") && caseOut.summary.contains(a.url.standardizedFileURL.path))
        #expect(FileManager.default.fileExists(atPath: a.url.path), "nothing outside the app is deleted")
        // The person is part of case B: case B's export may name them and is listed for the person.
        let personOut = try await f.state.erasePerson(p.id, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(personOut.report.refused == nil)
        #expect(personOut.report.exportsOutside.map(\.path) == [b.url.standardizedFileURL.path])
        #expect(personOut.summary.contains("the cases this person is part of"))
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        // The door now records where a file was written (v191).
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_document_outputs WHERE file_path = ?;", [.text(b.url.standardizedFileURL.path)]) == 1)
    }

    // MARK: (c) Keychain

    /// Every file that touches the Keychain and what it keeps there. None is case-scoped.
    static let keychainInventory: [String: String] = [
        "Kalsmritikosh/Storage/Database/LedgerEncryption.swift": "the ledger key (one per Mac)",
        "Kalsmritikosh/Forensics/AuditChainSecret.swift": "the audit-chain secret (one per Mac)",
        "Kalsmritikosh/Core/Security/ConformanceSeal.swift": "the conformance signing key (one per Mac)",
        "Kalsmritikosh/App/Store/Purchase.swift": "the purchase-cache key (one per Mac)",
        "Kalsmritikosh/App/Team/TeamCase.swift": "this installation's team signing key (one per Mac, not per case)",
        "Kalsmritikosh/App/Online/OnlineCenter.swift": "the person's AI keys (one per provider)",
        "Kalsmritikosh/Routing/Providers/CloudEndpointRegistry.swift": "configured cloud endpoint keys (one per endpoint)",
        "Kalsmritikosh/Sync/SyncSettings.swift": "the folder-sync key (one per Mac; a full erase stops syncing and forgets it)",
        "KalsmritikoshViewer/SyncLibrary.swift": "the viewer's sync key (iPhone/iPad viewer)",
    ]

    @Test("(c) no Keychain item is case-scoped (source audit); a case or person erasure removes none and leaves the ledger key; a full erase keeps it")
    func keychainHoldsNothingCaseScoped() async throws {
        let root = SmartMapS9Tests.repoRoot
        var found: [String] = []
        for dir in ["Kalsmritikosh", "SyncCore", "KalsmritikoshShare", "KalsmritikoshClipper", "KalsmritikoshViewer", "KalsmritikoshNetworkHelper"] {
            guard let en = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where u.pathExtension == "swift" {
                guard let text = try? String(contentsOf: u, encoding: .utf8), text.contains("kSecClass") else { continue }
                let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                found.append(rel)
                // The service and account of every item are fixed names or a provider/endpoint/kind — never a case.
                for line in text.components(separatedBy: "\n") where line.contains("kSecAttrAccount") || line.contains("kSecAttrService") {
                    #expect(!line.lowercased().contains("case"), "\(rel): a Keychain item named after a case: \(line)")
                }
            }
        }
        #expect(Set(found) == Set(Self.keychainInventory.keys), "Keychain users changed — classify them here and in docs/STORAGE_KEY_INVENTORY.md: \(found.sorted())")
        let doc = try String(contentsOf: root.appendingPathComponent("docs/STORAGE_KEY_INVENTORY.md"), encoding: .utf8)
        #expect(doc.contains("No Keychain item is case-scoped"))
        // Behaviour: erasures leave the ledger key; a full erase keeps it too (the emptied ledger stays encrypted with it).
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let before = LedgerKeychain.load()
        #expect(before != nil)
        _ = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(LedgerKeychain.load() == before, "a case erasure leaves the ledger key")
        _ = await f.state.deleteAllData()
        #expect(LedgerKeychain.load() == before, "a full erase keeps the ledger key")
    }

    // MARK: v191

    @Test("v191: v190 → v191 adds case_document_outputs.file_path and rebuilds the reference guard; a fault rolls v191 back")
    func migrationV191() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 190)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 191, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 191)))
        }
        #expect(try await db.currentUserVersion() == 190)
        let before = try await db.query("PRAGMA table_info(case_document_outputs);", []).compactMap { $0.string(1) }
        #expect(!before.contains("file_path"), "the faulted v191 left its column")
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        let after = try await db.query("PRAGMA table_info(case_document_outputs);", []).compactMap { $0.string(1) }
        #expect(after.contains("file_path"))
        #expect(SchemaMigrations.addedColumns(inMigration: 191).contains { $0.table == "case_document_outputs" && $0.column == "file_path" })
        let guardSQL = try await db.query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'case_cross_references_fixed';", []).first?.string(0) ?? ""
        #expect(guardSQL.contains("ledger_case_erase"), "the guard stands aside only for the erasure of the origin case")
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: (d) other cases' references

    @Test("(d) other cases' cross-references, history entries and review links to an erased case read \"erased case\" with no title or wording")
    func otherCasesReferencesReadErased() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let file = try #require(await f.state.caseFiles).file
        let record = try await file.addAllegation(caseID: f.caseA, text: "Secret allegation of case A", actor: "Tester")
        let origin = CaseMapNodeID(caseID: f.caseA, kind: .allegation, id: record)
        let review = try await file.startReview(caseID: f.caseB, of: f.caseA, purpose: "Secret review purpose", actor: "Tester")
        let src = try await file.addHistorySource(caseID: f.caseB, kind: .case, originCaseID: f.caseA, purpose: "Secret history purpose", scope: .records, actor: "Tester")
        let live = try await file.addCrossReference(caseID: f.caseB, historySourceID: src, origin: origin, mode: .live, purpose: "Secret reference purpose", actor: "Tester")
        let old = try await file.addCrossReference(caseID: f.caseB, historySourceID: review.historySource, origin: origin, mode: .live, purpose: "Secret old purpose", actor: "Tester")
        try await file.withdrawCrossReference(caseID: f.caseB, id: old, reason: "Secret withdrawal reason", actor: "Tester")
        _ = try await file.recordReviewFinding(caseID: f.caseB, referenceID: live, assessment: .observation, text: "The review's own finding", actor: "Tester")

        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(out.report.otherCaseReferences == 5, "two references, two history entries, one review link: \(out.report.otherCaseReferences)")
        #expect(out.report.otherCaseFindingsKept == 1)
        #expect(out.summary.contains("now read only “erased case”") && out.summary.contains("review finding(s) in other cases"))
        // Stored: no wording of the references survives, the references and history entries are withdrawn.
        for (t, cols) in [("case_cross_references", "purpose || ' ' || coalesce(withdrawn_reason, '')"),
                          ("case_history_sources", "purpose || ' ' || coalesce(withdrawn_reason, '')"),
                          ("case_review_of", "purpose || ' ' || coalesce(ended_reason, '')")] {
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \(t) WHERE (\(cols)) LIKE '%Secret%';") == 0, "\(t) kept wording")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_cross_references WHERE case_id = ? AND withdrawn_at IS NULL;", [.uuid(f.caseB)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_history_sources WHERE case_id = ? AND withdrawn_at IS NULL;", [.uuid(f.caseB)]) == 0)
        // Read: "erased case", no title, no record wording.
        let refs = try await file.crossReferences(caseID: f.caseB)
        #expect(refs.count == 2 && refs.allSatisfy { $0.purpose == CaseEraser.erasedCaseReferenceText })
        let sources = try await file.historySources(caseID: f.caseB)
        #expect(sources.count == 2 && sources.allSatisfy { $0.purpose == CaseEraser.erasedCaseReferenceText })
        let map = try #require(await CaseMapServiceFactory.map(f.state))
        let history = CaseHistoryReviewService(database: f.db, file: file, map: map)
        let view = try await history.resolve(caseID: f.caseB, referenceID: live)
        #expect(view.title == nil && view.wording == nil)
        guard case .unavailable(let why) = view.state else { Issue.record("an erased case's record was shown"); return }
        #expect(why.hasPrefix("Erased case"))
        let export = try await history.reviewExport(caseID: f.caseB)
        #expect(export.contains("Reviews: an erased case") && !export.contains("Case A — secret title") && !export.contains("Secret allegation"))
        // The guard still refuses any other edit of a reference (the exception is only for the erasure of its origin).
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_cross_references SET purpose = 'edited' WHERE id = ?;", [.uuid(live)])
        }
    }
}
