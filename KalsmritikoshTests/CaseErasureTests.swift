//
//  CaseErasureTests.swift
//  KalsmritikoshTests
//
//  K10 — case and person erasure on a booted app over two real documents and two cases:
//  a hold refuses with nothing deleted; a case erase removes every case-scoped row (append-only
//  ones included) and, when asked, the document only that case used, while the document another
//  case uses is kept; the other case is untouched; the erasure record carries no content; a person
//  erase removes the derived record and reports the documents that still name them.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case and person erasure (K10)", .serialized)
struct CaseErasureTests {

    struct Fixture {
        let state: AppState
        let db: Database
        let caseA: UUID, caseB: UUID
        let exclusiveFile: UUID, sharedFile: UUID
        let temp: URL
    }

    static func boot() async throws -> Fixture {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("k10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let state = await AppState(bookmarks: BookmarkStore())
        await state.boot(databaseURL: temp.appendingPathComponent("case.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            throw CaseErasureError.caseNotFound
        }
        var ids: [UUID] = []
        for name in ["investigator-press-release.txt", "lawyer-decision.txt"] {
            let dst = temp.appendingPathComponent(name)
            try FileManager.default.copyItem(at: try InvestigationCasePacks.url(name), to: dst)
            ids.append(try await ingest.ingest(fileAt: dst).fileRecord.id)
        }
        let now = Date()
        let sources = try #require(await state.workspaceSourceCoordinator)
        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        func open(_ title: String, _ files: Set<UUID>) async throws -> UUID {
            let ws = UUID()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(ws), .text(title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            try await sources.addSources(files, to: ws, at: now)
            let c = try await cases.createCase(workspaceID: ws, title: title, actor: "Tester", at: now)
            _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Tester", at: now)
            return c.id
        }
        let a = try await open("Case A — secret title", [ids[0], ids[1]])
        let b = try await open("Case B", [ids[1]])
        // Case work: an append-only action and a job result for each case.
        for (c, n) in [(a, 1), (b, 1)] {
            try await db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(c), .integer(Int64(n)), .text("Tester"), .text("note"), .text("secret detail"), .date(now)])
            try await JobResultRepository(database: db).save(caseID: c, jobID: "inv.linkage", family: .chronologyLinkage, state: .draft,
                                                            content: JobResultContent(rows: [JobResultRow(title: "secret row")]), actor: "Tester")
        }
        return Fixture(state: state, db: db, caseA: a, caseB: b, exclusiveFile: ids[0], sharedFile: ids[1], temp: temp)
    }

    static func count(_ db: Database, _ sql: String, _ b: [SQLValue]) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    @Test("A legal hold on one of the case's documents refuses the erase; nothing is deleted")
    func holdRefuses() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ko = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.string(0))
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(ko), .date(Date())])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused?.contains("legal hold") == true && out.report.erasureID == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseA)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
    }

    @Test("A case erase removes every case row and its exclusive document; the shared document and the other case stay; the record has no content")
    func caseErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        // Blank actor or reason is refused before anything happens.
        await #expect(throws: CaseErasureError.blankReason) {
            _ = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: " ", legalBasis: nil, actor: "Tester")
        }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: "GDPR art. 17", actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(out.report.sourcesErased == 1 && out.report.sourcesKeptShared == 1)
        // Every table that carries case_id holds nothing for case A — append-only case_actions included.
        let tables = try await f.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
            .compactMap { $0.string(0) }
        for t in tables where !CaseEraser.keptTables.contains(t) {
            let cols = try await f.db.query("PRAGMA table_info(\"\(t)\");", []).compactMap { $0.string(1) }
            guard cols.contains("case_id") else { continue }
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \"\(t)\" WHERE case_id = ?;", [.uuid(f.caseA)]) == 0, "\(t) kept case A rows")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 0)
        // The exclusive document and everything derived from it are gone; the shared one stays.
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'Goodyear';", []) == 0, "the erased text is not searchable")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.sharedFile)]) == 1)
        // Case B is untouched.
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseB)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM job_results WHERE case_id = ?;", [.uuid(f.caseB)]) == 1)
        // The erasure record: who, why, how much — no title, no detail, no row text; fixed.
        let rec = try #require(try await f.db.query("SELECT reason, legal_basis, rows_json, erased_by FROM case_erasures WHERE case_id = ?;", [.uuid(f.caseA)]).first)
        #expect(rec.string(0) == "Client request" && rec.string(1) == "GDPR art. 17" && rec.string(3) == "Tester")
        let json = rec.string(2) ?? ""
        #expect(!json.contains("secret") && json.contains("case_actions"))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_erasures SET reason = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_erasures;", []) }
        // Ordinary deletes on case B's append-only rows are still refused.
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_actions WHERE case_id = ?;", [.uuid(f.caseB)]) }
    }

    @Test("A case erase without its documents keeps them in the library and says so")
    func caseEraseKeepsDocuments() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Closed matter", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil && out.report.sourcesErased == 0 && out.report.sourcesKeptInLibrary == 1)
        #expect(out.summary.contains("stay in your library"))
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
    }

    @Test("A person erase removes the derived record, records a hash not the name, and reports documents that still name them")
    func personErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let id = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        let out = try await f.state.erasePerson(id, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(id)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entity_mentions WHERE entity_id = ?;", [.uuid(id)]) == 0)
        #expect(out.report.documentsStillNaming >= 1 && out.summary.contains("still name this person"))
        let rec = try #require(try await f.db.query("SELECT subject_sha256, rows_json FROM case_erasures WHERE scope = 'person';", []).first)
        #expect(rec.string(0)?.count == 64 && !(rec.string(1) ?? "").contains(name))
    }

    @Test("K5: a case report exports only while it is current — a source labelled privileged after the build stops the export")
    func caseReportExportReauthorised() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let findings = try #require(await f.state.investigationFindings)
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted,
                                                                  permitsPrivilegedMaterial: false, purpose: .export))
        let built = try await findings.buildFindings(caseID: f.caseA, access: access, actor: "Tester", at: Date())
        let check = try #require(await f.state.findingsExportCheck())
        try await check(built)   // current: passes

        // A cited source is labelled privileged after the build.
        let version = try #require(built.authorizedSourceVersionIDs.first)
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Tester", confirmationID: UUID(), privileged: true), reason: "privileged advice")
        await #expect(throws: ReportExportRefusal.sourcesWithdrawn(1)) { try await check(built) }
        #expect(ReportExportRefusal.sourcesWithdrawn(1).errorDescription?.contains("no longer cleared for export") == true)
    }

    // MARK: - Audit 182c7e4c regressions (A3–A5)

    static func firstKO(_ db: Database, _ file: UUID) async throws -> String {
        try #require(try await db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(file)]).first?.string(0))
    }
    static func firstBlock(_ db: Database, _ file: UUID) async throws -> String {
        try #require(try await db.query("""
            SELECT eb.id FROM evidence_blocks eb JOIN source_versions sv ON sv.id = eb.source_version_id
            WHERE sv.logical_source_id = ? LIMIT 1;
            """, [.uuid(file)]).first?.string(0))
    }

    @Test("A3: erasing one person never deletes a same-name person's facts; a held namesake document does not block it")
    func namesakeSafe() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let id = try #require(row.string(0)), name = try #require(row.string(1))
        // A distinct person with the same name, mentioned only in the other document (kept apart from
        // ours by an identity decision, so it has its own normalized key).
        let otherKO = try await Self.firstKO(f.db, f.sharedFile)
        let other = UUID().uuidString
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);", [.text(other), .text("person"), .text(name), .text(name.lowercased() + "|distinct"), .text(otherKO)])
        try await f.db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                            [.text(UUID().uuidString), .text(other), .text("person"), .text(name), .text(name.lowercased()), .text(otherKO)])
        // A fact naming the other person, sourced from their document; and one subject-linked to ours.
        let block = try await Self.firstBlock(f.db, f.sharedFile)
        let theirFact = UUID().uuidString, ourFact = UUID().uuidString
        for (fid, subject, blocks) in [(theirFact, Optional<String>.none, "[\"\(block)\"]"), (ourFact, Optional(id), "[]")] {
            try await f.db.exec("""
                INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.text(fid), subject.map { .text($0) } ?? .null, .text("x"), .text("defendant"), .text(name), .text("active"), .real(0.9), .text(blocks), .date(Date())])
        }
        // The namesake's document is on hold — that must not block erasing our person.
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("H"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(otherKO), .date(Date())])
        let out = try await f.state.erasePerson(try #require(UUID(uuidString: id)), reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM generic_facts WHERE id = ?;", [.text(theirFact)]) == 1, "the namesake's fact is kept")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM generic_facts WHERE id = ?;", [.text(ourFact)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.text(other)]) == 1, "the namesake is untouched")
        #expect(out.report.ambiguousFactsKept >= 1 && out.summary.contains("facts kept as ambiguous"))
    }

    @Test("A4: a hold on the case itself, or on one of its source versions, refuses the case erase; nothing changes")
    func caseAndVersionHolds() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let version = try #require(try await f.db.query("SELECT id FROM source_versions WHERE logical_source_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.string(0))
        for target in [f.caseA.uuidString, version] {
            let hold = UUID()
            try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("H"), .date(Date())])
            try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(target), .date(Date())])
            let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "r", legalBasis: nil, actor: "Tester")
            #expect(out.report.refused?.contains("legal hold") == true, "a hold on \(target) was missed")
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 1)
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
            try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        }
        // A refused erase leaves no operation record behind.
        let records = try FileManager.default.contentsOfDirectory(atPath: f.temp.path).filter { $0.hasPrefix(".case-erase-") }
        #expect(records.isEmpty)
    }

    @Test("A5: a case erase clears its drafts' captured legacy store, removes saved answers quoting its erased documents, and keeps others")
    func legacyAndAnswers() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let now = Date()
        let draft = UUID()
        try await f.db.exec("""
            INSERT INTO studio_records (id, studio, case_id, payload_json, payload_sha256, created_by, created_at, updated_by, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(draft), .text("siu"), .uuid(f.caseA), .text("{\"secret\":1}"), .text("h"), .text("T"), .date(now), .text("T"), .date(now)])
        try await f.db.exec("INSERT INTO studio_legacy_blobs (source_key, raw_blob, sha256, byte_count, captured_at) VALUES (?,?,?,?,?);",
                            [.text("legacy.siu"), .text("[{\"secret\":1}]"), .text("h"), .integer(14), .date(now)])
        try await f.db.exec("INSERT INTO studio_legacy_outcomes (source_key, element_index, record_id, outcome, detail, recorded_at) VALUES (?,?,?,?,?,?);",
                            [.text("legacy.siu"), .integer(0), .uuid(draft), .text("imported"), .text("ok"), .date(now)])
        // Two saved answers: one cites the exclusive (erased) document, one the shared (kept) one.
        let erasedKO = try await Self.firstKO(f.db, f.exclusiveFile), keptKO = try await Self.firstKO(f.db, f.sharedFile)
        var answerIDs: [String] = []
        for ko in [erasedKO, keptKO] {
            let a = UUID().uuidString, c = UUID().uuidString
            answerIDs.append(a)
            try await f.db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?,?,?,?,?);", [.text(a), .text("q"), .text("verifiedFinal"), .text("quoted text"), .date(now)])
            try await f.db.exec("INSERT INTO answer_claims (id, answer_id, claim_text, support_status, created_at) VALUES (?,?,?,?,?);", [.text(c), .text(a), .text("quoted"), .text("supported"), .date(now)])
            try await f.db.exec("INSERT INTO claim_evidence (claim_id, object_id) VALUES (?,?);", [.text(c), .text(ko)])
        }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await f.db.query("SELECT raw_blob FROM studio_legacy_blobs WHERE source_key = 'legacy.siu';", []).first?.string(0) == "")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM studio_erasures WHERE record_id = ?;", [.uuid(draft)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.text(answerIDs[0])]) == 0, "the answer quoting the erased document is removed")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.text(answerIDs[1])]) == 1, "an answer from a kept document stays")
        #expect(out.report.answersRemoved == 1)
    }

    @Test("A5: a case erase interrupted after its ledger commit finishes its file steps at the next launch")
    func interruptedFileStepsResume() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let vault = EvidenceVault(root: f.temp.appendingPathComponent("EvidenceVault", isDirectory: true))
        let orphan = try await vault.store(Data("copy of an erased document".utf8))
        let kept = try await vault.store(Data("copy still used".utf8))
        let used = try #require(try await f.db.query("SELECT id FROM source_versions LIMIT 1;", []).first?.string(0))
        try await f.db.exec("PRAGMA foreign_keys = OFF;")
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE id = ?;", [.text(kept), .text(used)])
        try await f.db.exec("PRAGMA foreign_keys = ON;")
        // A record for an erased case (the case no longer exists) and one whose case still exists.
        let gone = UUID()
        let ledgerURL = f.temp.appendingPathComponent("case.sqlite")
        let recordGone = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: gone)
        AppState.writeCaseEraseRecord(recordGone, vault: [orphan, kept], dropVectorCache: false)
        let recordLive = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: f.caseB)
        AppState.writeCaseEraseRecord(recordLive, vault: [orphan], dropVectorCache: false)
        await AppState.resumePendingCaseErasures(besideLedgerAt: ledgerURL, database: f.db)
        #expect(await vault.contains(orphan) == false, "the erased case's copy is removed")
        #expect(await vault.contains(kept), "a copy a remaining version uses is never removed")
        #expect(!FileManager.default.fileExists(atPath: recordGone.path) && !FileManager.default.fileExists(atPath: recordLive.path))
    }
}
