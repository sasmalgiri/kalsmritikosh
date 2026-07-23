//
//  EvidenceDimensionMigrationTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2 (Commit B). The additive v62 migration + repository dual-write. Proves:
//  fresh v62 reaches the version and adds the columns; new rows dual-write the legacy
//  status AND the separated dimensions; history_items keeps its own review_status while
//  gaining review_disposition; the deterministic backfill maps accepted→confirmed; a
//  re-run of migrate() is a safe no-op (self-heal); and an existing history artifact
//  still reopens with its evidence intact (no row loss).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 — v62 evidence-dimension migration + dual-write")
struct EvidenceDimensionMigrationTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDB() async throws -> Database {
        let db = try await rawDB()
        try await SchemaMigrations.migrate(db)
        return db
    }

    /// A database with NO migrations applied — the caller drives migrate(through:) so it
    /// can build a genuine intermediate-version schema.
    private func rawDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Database(url: dir.appendingPathComponent("t.sqlite"))
    }

    private func columns(_ db: Database, _ table: String) async throws -> Set<String> {
        let rows = try await db.query("PRAGMA table_info(\(table));", [])
        return Set(rows.compactMap { $0.string(1) })
    }

    @Test("Fresh migration reaches v62 and adds the dimension columns to all three tables")
    func freshV62() async throws {
        let db = try await freshDB()
        #expect(SchemaMigrations.latestVersion >= 62)   // v62 columns land from v62 onward
        #expect(SchemaMigrations.migrationListIsConsistent)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)

        let gf = try await columns(db, "generic_facts")
        for c in ["evidence_basis", "review_disposition", "proposal_origin", "availability_status", "conflict_status", "legacy_status"] {
            #expect(gf.contains(c))
        }
        let tc = try await columns(db, "temporal_claims")
        #expect(tc.isSuperset(of: ["evidence_basis", "review_disposition", "proposal_origin", "availability_status", "conflict_status", "legacy_status"]))
        let hi = try await columns(db, "history_items")
        #expect(hi.isSuperset(of: ["evidence_basis", "review_disposition", "proposal_origin", "availability_status", "legacy_status"]))
        #expect(hi.contains("review_status"))          // legacy review column preserved
        #expect(!hi.contains("conflict_status"))        // history conflict stays DERIVED
    }

    @Test("GenericFact dual-write populates legacy status AND separated dimensions")
    func genericFactDualWrite() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        let fact = GenericFact(subjectID: UUID(), subjectLabel: "S", field: "employer",
                               value: "Orchid", status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [UUID()])
        try await repo.upsert(fact)
        let r = try #require(try await db.query("""
        SELECT status, evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
        FROM generic_facts WHERE id = ?;
        """, [.uuid(fact.id)]).first)
        #expect(r.string(0) == "SOURCE_ASSERTED")       // legacy preserved
        #expect(r.string(1) == "sourceAsserted")         // basis
        #expect(r.string(2) == "unreviewed")             // review
        #expect(r.string(3) == "importedLegacy")         // origin NOT inferred as sourceExtraction
        #expect(r.string(4) == "present")                // availability
        #expect(r.string(5) == "none")                   // conflict
        #expect(r.string(6) == "SOURCE_ASSERTED")        // legacy_status raw value
    }

    @Test("History item dual-write maps review status → disposition; conflict derived not stored")
    func historyItemDualWrite() async throws {
        let db = try await freshDB()
        let repo = HistoryArtifactRepository(database: db)
        let subjectID = UUID()
        let item = HistoryItem(subject: .person(subjectID), kind: .stateStart, title: "Role",
                               evidenceStatus: .contradicted, confidence: 0.6,
                               evidence: [EvidenceReference(objectID: UUID())],
                               reviewStatus: .accepted)
        let outline = HistoryOutline(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "S",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            corpusSnapshotID: nil, items: [item],
            chapters: [HistoryChapterPlan(ordinal: 0, title: "c", itemIDs: [item.id])],
            actors: [subjectID], relationships: [],
            coverage: HistoryCoverage(totalItems: 1, datedItems: 0, undatedItems: 1, earliest: nil, latest: nil,
                                      evidenceObjectCount: 1, assertionCount: 0, genericFactCount: 0, eventCount: 0))
        let result = HistoryReconstructionResult(subject: outline.subject, outline: outline, claims: [],
                                                 engineVersion: "history-engine-1", generatedAt: clock)
        _ = try await repo.save(result, at: clock)

        let r = try #require(try await db.query("""
        SELECT status, review_status, evidence_basis, review_disposition, availability_status, legacy_status
        FROM history_items WHERE id = ?;
        """, [.uuid(item.id)]).first)
        #expect(r.string(0) == "CONTRADICTED")           // legacy status preserved
        #expect(r.string(1) == "accepted")               // own review_status untouched
        #expect(r.string(2) == "unknownLegacy")          // contradicted → basis unknown
        #expect(r.string(3) == "confirmed")              // accepted → confirmed (NOT from evidence status)
        #expect(r.string(5) == "CONTRADICTED")           // legacy_status raw
    }

    @Test("Deterministic backfill maps a pre-existing review_status to review_disposition")
    func reviewDispositionBackfill() async throws {
        let db = try await freshDB()
        // Simulate a pre-v62 row: review_disposition left NULL, review_status set.
        let id = UUID()
        try await db.exec("""
        INSERT INTO history_items (id, artifact_id, item_kind, title, status, confidence, review_status, review_disposition)
        VALUES (?, ?, 'event', 'x', 'SOURCE_ASSERTED', 0.5, 'accepted', NULL);
        """, [.uuid(id), .uuid(UUID())])
        // Run the same backfill the migration applies.
        try await db.exec("""
        UPDATE history_items SET review_disposition = CASE
            WHEN review_status IS NULL OR review_status = 'unreviewed' THEN 'unreviewed'
            WHEN review_status = 'accepted'  THEN 'confirmed'
            WHEN review_status = 'corrected' THEN 'corrected'
            WHEN review_status = 'rejected'  THEN 'rejected'
            ELSE 'needsReview'
        END
        WHERE review_disposition IS NULL;
        """, [])
        let r = try #require(try await db.query("SELECT review_disposition FROM history_items WHERE id = ?;", [.uuid(id)]).first)
        #expect(r.string(0) == "confirmed")
    }

    @Test("Re-running migrate() is a safe no-op and preserves rows (no loss)")
    func idempotentAndNoRowLoss() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        try await repo.upsert(GenericFact(subjectID: UUID(), subjectLabel: "S", field: "employer",
                                          value: "Orchid", status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [UUID()]))
        #expect(try await repo.count() == 1)

        // A stale counter must self-heal without re-running DDL (which would throw).
        try await db.setUserVersion(2)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await repo.count() == 1)              // row survived
        // A second ordinary migrate() is also a no-op.
        try await SchemaMigrations.migrate(db)
        #expect(try await repo.count() == 1)
    }

    @Test("Genuine v61 → v62: legacy rows migrate with no loss, backfill applies, evidence reopens")
    func realV61ToV62() async throws {
        let db = try await rawDB()
        try await SchemaMigrations.migrate(db, through: 61)
        #expect(try await db.currentUserVersion() == 61)
        // v62 columns must NOT exist yet.
        #expect(!(try await columns(db, "generic_facts")).contains("evidence_basis"))

        // Insert genuine legacy rows using the v61 column shapes only.
        let factID = UUID(), subjectID = UUID()
        try await db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at)
        VALUES (?, ?, 'S', 'employer', 'Orchid', NULL, 'SOURCE_ASSERTED', 0.7, '[]', 0);
        """, [.uuid(factID), .uuid(subjectID)])
        try await db.exec("""
        INSERT INTO temporal_claims (id, subject_id, predicate, object_json, status, confidence, extractor_id, extractor_version, created_at)
        VALUES (?, ?, 'worked_for', '{}', 'INFERRED', 0.5, 'x', '1', 0);
        """, [.uuid(UUID()), .uuid(subjectID)])
        let artifactID = UUID(), itemID = UUID()
        try await db.exec("""
        INSERT INTO history_artifacts (id, subject_kind, subject_label, engine_version, title, created_at)
        VALUES (?, 'person', 'S', 'history-engine-1', 'S', 0);
        """, [.uuid(artifactID)])
        try await db.exec("""
        INSERT INTO history_items (id, artifact_id, item_kind, title, status, confidence, review_status)
        VALUES (?, ?, 'event', 'e', 'SOURCE_ASSERTED', 0.8, 'accepted');
        """, [.uuid(itemID), .uuid(artifactID)])
        try await db.exec("""
        INSERT INTO history_item_evidence (history_item_id, knowledge_object_id, evidence_block_id, evidence_role)
        VALUES (?, ?, '', 'supports');
        """, [.uuid(itemID), .uuid(UUID())])

        // Step to v62.
        try await SchemaMigrations.migrate(db, through: 62)
        #expect(try await db.currentUserVersion() == 62)

        // No row loss; legacy values unchanged; dimension columns present but NULL for
        // legacy rows (read-time fallback is Commit C); review_disposition backfilled.
        let gf = try #require(try await db.query("SELECT status, evidence_basis FROM generic_facts WHERE id = ?;", [.uuid(factID)]).first)
        #expect(gf.string(0) == "SOURCE_ASSERTED")     // unchanged
        #expect(gf.string(1) == nil)                    // legacy row: dimension NULL
        let hi = try #require(try await db.query("SELECT status, review_status, review_disposition FROM history_items WHERE id = ?;", [.uuid(itemID)]).first)
        #expect(hi.string(0) == "SOURCE_ASSERTED")      // unchanged
        #expect(hi.string(1) == "accepted")             // own review column preserved
        #expect(hi.string(2) == "confirmed")            // backfilled accepted → confirmed
        // Evidence still reopens.
        #expect(try await HistoryArtifactRepository(database: db).evidenceCount(itemID: itemID) == 1)
    }

    @Test("Interrupted v62 rolls back cleanly: version stays 61, no partial columns, rows survive")
    func interruptedV62Rollback() async throws {
        let db = try await rawDB()
        try await SchemaMigrations.migrate(db, through: 61)
        let factID = UUID()
        try await db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at)
        VALUES (?, ?, 'S', 'employer', 'Orchid', NULL, 'SOURCE_ASSERTED', 0.7, '[]', 0);
        """, [.uuid(factID), .uuid(UUID())])

        // Drive the REAL v62 DDL plus a deliberately failing trailing statement, in the
        // same SAVEPOINT the migrator uses.
        let badV62 = try #require(SchemaMigrations.migrationSQL(for: 62)) + "\nUPDATE definitely_not_a_table SET z = 1;"
        var threw = false
        do { try await SchemaMigrations.applyOne(db, version: 62, sql: badV62) }
        catch { threw = true }
        #expect(threw)

        // Rollback guarantees: counter at 61, no v62 columns, legacy row intact.
        #expect(try await db.currentUserVersion() == 61)
        #expect(!(try await columns(db, "generic_facts")).contains("evidence_basis"))
        #expect(try await db.query("SELECT status FROM generic_facts WHERE id = ?;", [.uuid(factID)]).first?.string(0) == "SOURCE_ASSERTED")

        // A subsequent real migration still succeeds.
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect((try await columns(db, "generic_facts")).contains("evidence_basis"))
    }

    @Test("TemporalClaim dual-write populates all six dimensions plus legacy status")
    func temporalClaimDualWrite() async throws {
        let db = try await freshDB()
        let claim = TemporalClaim(subjectID: UUID(), predicate: "worked_for", object: .literal("Orchid"),
                                  status: .inferred, confidence: 0.5,
                                  extractorID: "x", extractorVersion: "1", createdAt: clock)
        try await TemporalClaimRepository(database: db).insert(claim)
        let r = try #require(try await db.query("""
        SELECT status, evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
        FROM temporal_claims WHERE id = ?;
        """, [.uuid(claim.id)]).first)
        #expect(r.string(0) == "INFERRED")
        #expect(r.string(1) == "inferred")
        #expect(r.string(2) == "unreviewed")
        #expect(r.string(3) == "importedLegacy")     // NOT modelProposed
        #expect(r.string(4) == "present")
        #expect(r.string(5) == "none")
        #expect(r.string(6) == "INFERRED")
    }

    @Test("Partial / null / unknown / divergent dimension rows all load without being dropped")
    func partialDimensionRowsLoad() async throws {
        let db = try await freshDB()
        let subjectID = UUID()
        func insert(_ id: UUID, basis: String?, legacy: String?) async throws {
            try await db.exec("""
            INSERT INTO generic_facts (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at, evidence_basis, legacy_status)
            VALUES (?, ?, 'S', 'employer', 'Orchid', NULL, 'SOURCE_ASSERTED', 0.7, '[]', 0, ?, ?);
            """, [.uuid(id), .uuid(subjectID),
                  basis.map { SQLValue.text($0) } ?? .null,
                  legacy.map { SQLValue.text($0) } ?? .null])
        }
        let allNull = UUID(), partial = UUID(), unknown = UUID(), divergent = UUID()
        try await insert(allNull, basis: nil, legacy: nil)                       // all dims null
        try await insert(partial, basis: "directlyObserved", legacy: nil)        // partly populated
        try await insert(unknown, basis: "SOME_FUTURE_BASIS", legacy: nil)       // unknown future value
        try await insert(divergent, basis: nil, legacy: "HUMAN_CONFIRMED")       // legacy_status ≠ status

        // The current (status-based) read must not drop any of them.
        let facts = try await GenericFactRepository(database: db).facts(subjectID: subjectID)
        let ids = Set(facts.map(\.id))
        #expect(ids.isSuperset(of: [allNull, partial, unknown, divergent]))
        #expect(facts.count == 4)
    }

    @Test("An existing history artifact still reopens with its evidence after v62")
    func artifactStillReopens() async throws {
        let db = try await freshDB()
        let repo = HistoryArtifactRepository(database: db)
        let subjectID = UUID()
        let item = HistoryItem(subject: .person(subjectID), kind: .event, title: "e",
                               evidenceStatus: .sourceAsserted, confidence: 0.8,
                               evidence: [EvidenceReference(objectID: UUID())])
        let outline = HistoryOutline(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "S",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            corpusSnapshotID: nil, items: [item], chapters: [], actors: [subjectID], relationships: [],
            coverage: HistoryCoverage(totalItems: 1, datedItems: 0, undatedItems: 1, earliest: nil, latest: nil,
                                      evidenceObjectCount: 1, assertionCount: 0, genericFactCount: 0, eventCount: 0))
        let id = try await repo.save(HistoryReconstructionResult(subject: outline.subject, outline: outline,
                                     claims: [], engineVersion: "history-engine-1", generatedAt: clock), at: clock)
        #expect(try await repo.header(id: id) != nil)
        #expect(try await repo.evidenceCount(itemID: item.id) == 1)
    }
}
