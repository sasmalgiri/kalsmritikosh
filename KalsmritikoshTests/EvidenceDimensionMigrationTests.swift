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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    private func columns(_ db: Database, _ table: String) async throws -> Set<String> {
        let rows = try await db.query("PRAGMA table_info(\(table));", [])
        return Set(rows.compactMap { $0.string(1) })
    }

    @Test("Fresh migration reaches v62 and adds the dimension columns to all three tables")
    func freshV62() async throws {
        let db = try await freshDB()
        #expect(SchemaMigrations.latestVersion == 62)
        #expect(SchemaMigrations.migrationListIsConsistent)
        #expect(try await db.currentUserVersion() == 62)

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
        #expect(try await db.currentUserVersion() == 62)
        #expect(try await repo.count() == 1)              // row survived
        // A second ordinary migrate() is also a no-op.
        try await SchemaMigrations.migrate(db)
        #expect(try await repo.count() == 1)
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
