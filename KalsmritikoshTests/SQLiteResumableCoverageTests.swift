//
//  SQLiteResumableCoverageTests.swift
//  KalsmritikoshTests
//
//  F04/F05 (residual, 2026-09-29 review) — SQLite ingest stopped each table at a hard 500,000-row cap
//  and gave only the first 5,000 rows a citable block; disclosing the limits did not make the rest
//  ingested. A run now stops at a WORK budget with a durable per-table cursor, every processed row is
//  committed WITH its own evidence block, and later runs (across coordinator restarts) continue over
//  the exact acquired bytes until the final row. Tiny configured limits exercise every continuation:
//  a run budget of 3 rows, pages of 2 rows, three 11-row tables — negative and zero rowids, a user
//  column that shadows `rowid`, and a WITHOUT ROWID table with a composite key.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F04/F05 — SQLite coverage resumes past page budgets to the final row, with exact citations", .serialized)
@MainActor
struct SQLiteResumableCoverageTests {

    private static let rowsPerTable = 11
    private static let tables = 3

    /// Unique marker per row; the trailing "|" keeps "mk-a-1|" from matching inside "mk-a-10|".
    private static func marker(_ table: String, _ i: Int) -> String { "mk-\(table)-\(i)|" }

    private func makeSource(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("resume.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }
        var sql = [
            "CREATE TABLE a_neg(id INTEGER PRIMARY KEY, body TEXT);",
            // A user column literally named `rowid` shadows that alias; the walk must use another.
            "CREATE TABLE b_shadow(rowid TEXT, body TEXT);",
            // Composite key, walked by row-value keyset; includes a negative second component.
            "CREATE TABLE c_wr(g TEXT NOT NULL, n INTEGER NOT NULL, body TEXT, PRIMARY KEY (g, n)) WITHOUT ROWID;",
            "BEGIN;"]
        for i in 0..<Self.rowsPerTable {
            sql.append("INSERT INTO a_neg VALUES(\(i - 2), '\(Self.marker("a", i))');")          // rowids -2, -1, 0, 1 … 8
            sql.append("INSERT INTO b_shadow VALUES('shadow', '\(Self.marker("b", i))');")
            sql.append("INSERT INTO c_wr VALUES('\(i < 6 ? "g1" : "g2")', \(i < 6 ? i - 3 : i), '\(Self.marker("c", i))');")
        }
        sql.append("COMMIT;")
        for s in sql { #expect(sqlite3_exec(h, s, nil, nil, nil) == SQLITE_OK, "\(s)") }
        return url
    }

    /// A fresh coordinator over the SAME ledger + vault — a restart between runs.
    private func coordinator(db: Database, vault: EvidenceVault) async throws -> IngestCoordinator {
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault)),
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 1 << 30, deferWholeFileAboveBytes: 1 << 31,
                                                   resumable: ResumableStreamBudget(unitsPerRun: 3, unitsPerRecord: 2)))
        return c
    }

    private func objectText(_ db: Database, fileID: UUID) async throws -> String {
        try await db.query("SELECT content FROM knowledge_objects WHERE file_id = ?;", [.uuid(fileID)])
            .compactMap { $0.string(0) }.joined(separator: "\n")
    }

    @Test("Budget 3 / page 2: every row of three 11-row tables is committed once, with exact deferred counts and citations")
    func resumesToTheFinalRow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlres-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let source = try makeSource(in: dir)
        let total = Self.rowsPerTable * Self.tables
        let cursors = StreamCursorRepository(database: db)
        let readiness = SourceReadinessRepository(database: db)

        // Run 1.
        let svid = try #require(try await coordinator(db: db, vault: vault).ingest(fileAt: source).sourceVersionID)
        var runs = 1
        while true {
            let coverage = try #require(try await cursors.coverage(sourceVersionID: svid))
            #expect(coverage.discovered == total, "every table is counted on every run")
            #expect(coverage.processed == min(total, 3 * runs), "run \(runs) processes exactly its budget")
            #expect(coverage.deferred == total - coverage.processed, "exact deferred count after run \(runs)")
            let text = try await readiness.snapshot(sourceVersionID: svid).dimension(.textExtraction)
            let structure = try await readiness.snapshot(sourceVersionID: svid).dimension(.structuralExtraction)
            if coverage.deferred > 0 {
                #expect(text?.state == .partial, "a paused budget is never labelled complete (run \(runs))")
                #expect(text?.detail?.contains("\(coverage.deferred) deferred") == true, "\(text?.detail ?? "nil")")
                #expect(structure?.state == .partial)
            } else {
                break
            }
            // Restart: a NEW coordinator resumes from the durable cursors.
            try await coordinator(db: db, vault: vault).resumeStreamedIngest(sourceVersionID: svid)
            runs += 1
            try #require(runs <= 20, "resume never reached the final row")
        }
        #expect(runs == 11, "33 rows at 3 per run")

        // No missing / duplicate rows in the searchable records.
        let fileID = try #require(try await db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(svid)]).first?.uuid(0))
        let text = try await objectText(db, fileID: fileID)
        for t in ["a", "b", "c"] {
            for i in 0..<Self.rowsPerTable {
                #expect(text.components(separatedBy: Self.marker(t, i)).count - 1 == 1, "row \(t)\(i) must appear exactly once")
            }
        }
        let outcomes = try await coordinator(db: db, vault: vault).streamRecordOutcomes(sourceVersionID: svid)
        #expect(!outcomes.isEmpty && outcomes.allSatisfy { $0.state == .committed })

        // One active row block per row, each with a distinct record key and exactly one owner.
        let active = try await EvidenceStore(database: db).blocks(forVersion: svid).filter { $0.kind == .tableRow }
        var owners: [UUID: Int] = [:]
        for r in try await db.query("""
            SELECT o.evidence_block_id, COUNT(*) FROM evidence_block_objects o
              JOIN evidence_blocks b ON b.id = o.evidence_block_id WHERE b.source_version_id = ? GROUP BY o.evidence_block_id;
            """, [.uuid(svid)]) { if let id = r.uuid(0) { owners[id] = Int(r.int(1) ?? 0) } }
        func recordKey(_ b: EvidenceBlock) -> String? {
            if case .string(let k)? = b.attributes[SQLiteRecordKey.attributeKey]?.value { return k }
            return nil
        }
        #expect(active.count == total)
        #expect(Set(active.compactMap(recordKey)).count == total, "record keys are distinct")
        #expect(active.allSatisfy { owners[$0.id] == 1 }, "each row block has exactly one owner")
        // The walk used the rowid aliases correctly: negative + zero rowids are keyed by rowid, the
        // shadowed table by its real rowid (1…11), the WITHOUT ROWID table by key-order position.
        let keys = Set(active.compactMap(recordKey))
        #expect(keys.contains(SQLiteRecordKey.key(table: "a_neg", rowID: -2)) && keys.contains(SQLiteRecordKey.key(table: "a_neg", rowID: 0)))
        #expect(keys.contains(SQLiteRecordKey.key(table: "b_shadow", rowID: 11)))
        #expect(keys.contains(SQLiteRecordKey.key(table: "c_wr", position: 10)))

        // Citation reopening for the first, a middle and the final row.
        let store = EvidenceStore(database: db)
        for (t, i) in [("a", 0), ("b", 5), ("c", Self.rowsPerTable - 1)] {
            let row = try #require(active.first { $0.rawText.contains(Self.marker(t, i)) }, "no block for \(t)\(i)")
            let blockID = row.id
            #expect(row.locator.isResolvable, "the cited row has a source locator")
            guard case .resolved(let r)? = try await store.resolveCanonicalBlocks([blockID]).first else {
                Issue.record("block for \(t)\(i) does not resolve to one owner"); continue
            }
            #expect(r.sourceVersionID == svid)
            let owner = try #require(try await db.query("SELECT content FROM knowledge_objects WHERE id = ?;", [.uuid(r.knowledgeObjectID)]).first?.string(0))
            #expect(owner.contains(Self.marker(t, i)), "the owning record carries the cited row")
            // Reopen the version's exact bytes and find the cited row in them.
            let resolved = try await SourceVersionByteResolver(database: db, vault: vault).resolve(sourceVersionID: svid, at: Date())
            defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
            let reopened = try ExternalSQLiteSource(originalPath: resolved.snapshotURL)
            let table = ["a": "a_neg", "b": "b_shadow", "c": "c_wr"][t]!
            #expect(try reopened.query("SELECT COUNT(*) FROM \(table) WHERE body = ?;", binds: [.text(Self.marker(t, i))]).first?.int(0) == 1)
        }

        // Complete only now.
        let snap = try await readiness.snapshot(sourceVersionID: svid)
        #expect(snap.dimension(.textExtraction)?.state == .ready)
        #expect(snap.dimension(.structuralExtraction)?.state == .ready)
        // A further resume changes nothing.
        let blocksBefore = try await db.query("SELECT COUNT(*) FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(svid)]).first?.int(0)
        try await coordinator(db: db, vault: vault).resumeStreamedIngest(sourceVersionID: svid)
        #expect(try await db.query("SELECT COUNT(*) FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(svid)]).first?.int(0) == blocksBefore)
        #expect(try await objectText(db, fileID: fileID) == text)
    }

    @Test("The composite-key cursor round-trips every storage class (integer, real incl. infinity, text, blob)")
    func compositeCursorContract() throws {
        let c = SQLiteRecordKey.Cursor(rowID: nil, key: [.text("g1"), .int(-3), .real(2.5), .blob(Data([0, 1, 2])), .real(.infinity)], offset: 7)
        #expect(SQLiteRecordKey.Cursor.parse(c.serialized()) == c)
    }

    @Test("A bounded re-parse that drops rows the ledger cites is refused, not activated")
    func reparseCannotDropCitedRows() {
        func row(_ k: String) -> EvidenceBlock {
            EvidenceBlock(documentID: UUID(), ordinal: 0, kind: .tableRow, rawText: k,
                          locator: SourceLocator(sectionPath: ["db", "t", k]),
                          attributes: [SQLiteRecordKey.attributeKey: AnyCodable(.string(k))])
        }
        let committed = (0..<6).map { row("t\u{1F}r\($0)") }
        let fresh = ParsedDocument(logicalSourceID: UUID(), sourceVersionID: UUID(), filename: "db", detectedType: .sqlite,
                                   contentHash: "h", blocks: Array(committed.prefix(4)), extractionStatus: .partial)
        #expect(SourceReprocessingCoordinator.activationRefusal(fresh: fresh, committed: committed, priorStructural: .partial)?
            .contains("drops 2 record") == true)
    }
}
