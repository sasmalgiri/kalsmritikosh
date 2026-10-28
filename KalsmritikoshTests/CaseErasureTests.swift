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
}
