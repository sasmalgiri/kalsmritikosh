//
//  EvidenceRevisionTests.swift
//  KalsmritikoshTests
//
//  F15 (residual, 2026-09-29 review) — readiness proofs were compared against an aggregate
//  fingerprint (counts, rowid sums, text lengths, distinct owners). An equal-length text or locator
//  change, or an ownership swap that preserved owner counts, left the fingerprint — and therefore a
//  stale "ready" — unchanged. Proofs now depend on genuine per-version, per-lane revisions that the
//  database bumps on every insert / update / delete / ownership change / generation switch.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F15 — readiness proofs follow real evidence revisions", .serialized)
@MainActor
struct EvidenceRevisionTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let readiness: SourceReadinessRepository; let dir: URL }

    private func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evrev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let readiness = SourceReadinessRepository(database: db)
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: readiness,
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .referenced)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        return Rig(c: c, db: db, readiness: readiness, dir: dir)
    }

    /// Several paragraphs, each long enough to become its own chunk.
    private func ingest(_ r: Rig, _ name: String, lead: String = "Alice approved") async throws -> UUID {
        let paragraphs = (0..<4).map { i in
            "\(lead) item \(i). " + String(repeating: "The committee recorded its reasons in full detail. ", count: 40)
        }
        let url = r.dir.appendingPathComponent(name)
        try paragraphs.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        return try #require(try await r.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
    }

    private func proofIsCurrent(_ r: Rig, _ svid: UUID, _ d: SourceReadinessDimension) async throws -> Bool {
        try await r.readiness.proofIsCurrent(sourceVersionID: svid, dimension: d)
    }

    /// Re-affirm a dimension's current state so its proof is stamped against today's evidence.
    private func restamp(_ r: Rig, _ svid: UUID, _ d: SourceReadinessDimension) async throws {
        let snap = try await r.readiness.snapshot(sourceVersionID: svid)
        let rec = try #require(snap.dimension(d))
        try await r.readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: svid, expectedRevision: snap.aggregateRevision,
            updates: [SourceReadinessDimensionUpdate(dimension: d, state: rec.state, action: .reconcile,
                                                     applicability: rec.applicability, completedUnits: rec.completedUnits,
                                                     totalUnits: rec.totalUnits, basis: rec.basis, detail: rec.detail)],
            producerID: "test.restamp", producerVersion: rec.producerVersion, occurredAt: Date()))
    }

    @Test("An equal-length chunk text change (approved → rejected) makes the indexing proof stale — structure stays current")
    func equalLengthTextChange() async throws {
        let r = try await rig()
        let svid = try await ingest(r, "text.txt")
        #expect(try await proofIsCurrent(r, svid, .indexing))
        let n = try await r.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", [.uuid(svid)]).first?.int(0) ?? 0
        #expect(n >= 2, "fixture: several chunks")
        try await r.db.exec("""
            UPDATE chunks SET text = replace(text, 'Alice approved', 'Alice rejected')
             WHERE rowid = (SELECT MIN(rowid) FROM chunks WHERE source_version_id = ?);
            """, [.uuid(svid)])
        #expect(!(try await proofIsCurrent(r, svid, .indexing)), "an equal-length change left the proof current")
        #expect(try await proofIsCurrent(r, svid, .structuralExtraction), "a chunk change must not stale the structure proof")
    }

    @Test("An equal-length locator change makes the structure proof stale")
    func equalLengthLocatorChange() async throws {
        let r = try await rig()
        let svid = try await ingest(r, "loc.txt")
        #expect(try await proofIsCurrent(r, svid, .structuralExtraction))
        let row = try #require(try await r.db.query("""
            SELECT id, locator FROM evidence_blocks WHERE source_version_id = ? AND locator LIKE '%1%' ORDER BY ordinal LIMIT 1;
            """, [.uuid(svid)]).first)
        let changed = (row.string(1) ?? "").replacingOccurrences(of: "1", with: "7")
        try await r.db.exec("UPDATE evidence_blocks SET locator = ? WHERE id = ?;", [.text(changed), .uuid(try #require(row.uuid(0)))])
        #expect(!(try await proofIsCurrent(r, svid, .structuralExtraction)), "an equal-length locator change left the proof current")
    }

    @Test("An ownership swap that preserves counts and distinct owners makes the proofs stale")
    func ownershipSwap() async throws {
        let r = try await rig()
        let svid = try await ingest(r, "own.txt")
        let blocks = try await r.db.query("""
            SELECT b.id, ebo.knowledge_object_id FROM evidence_blocks b JOIN evidence_block_objects ebo ON ebo.evidence_block_id = b.id
             WHERE b.source_version_id = ? ORDER BY b.ordinal;
            """, [.uuid(svid)]).compactMap { row -> (UUID, UUID)? in
                guard let b = row.uuid(0), let k = row.uuid(1) else { return nil }; return (b, k)
            }
        #expect(blocks.count >= 2)
        // A second object owns the second block; stamp that as the verified state.
        let ko2 = UUID(), file = try #require(try await r.db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(blocks[0].1)]).first?.uuid(0))
        try await r.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(ko2), .uuid(file), .text("txt"), .text("second"), .real(0), .real(0)])
        try await r.db.exec("UPDATE evidence_block_objects SET knowledge_object_id = ? WHERE evidence_block_id = ?;", [.uuid(ko2), .uuid(blocks[1].0)])
        try await restamp(r, svid, .structuralExtraction)
        #expect(try await proofIsCurrent(r, svid, .structuralExtraction))
        // Swap the two owners: same row count, same rowids, same distinct owners.
        try await r.db.exec("UPDATE evidence_block_objects SET knowledge_object_id = ? WHERE evidence_block_id = ?;", [.uuid(ko2), .uuid(blocks[0].0)])
        try await r.db.exec("UPDATE evidence_block_objects SET knowledge_object_id = ? WHERE evidence_block_id = ?;", [.uuid(blocks[0].1), .uuid(blocks[1].0)])
        #expect(!(try await proofIsCurrent(r, svid, .structuralExtraction)), "an ownership swap left the proof current")
    }

    @Test("Deleting one of several chunks makes the indexing proof stale")
    func deleteOneChunk() async throws {
        let r = try await rig()
        let svid = try await ingest(r, "del.txt")
        try await r.db.exec("DELETE FROM chunks WHERE rowid = (SELECT MAX(rowid) FROM chunks WHERE source_version_id = ?);", [.uuid(svid)])
        #expect(!(try await proofIsCurrent(r, svid, .indexing)))
    }

    @Test("A mutation between measurement and stamping is refused; the stamp never claims newer evidence")
    func mutationBetweenMeasureAndStamp() async throws {
        let r = try await rig()
        let svid = try await ingest(r, "race.txt")
        let measured = try await r.readiness.evidenceRevisions(sourceVersionID: svid)
        try await r.db.exec("UPDATE evidence_blocks SET raw_text = raw_text || '' , normalized_text = normalized_text WHERE rowid = (SELECT MIN(rowid) FROM evidence_blocks WHERE source_version_id = ?);", [.uuid(svid)])
        let snap = try await r.readiness.snapshot(sourceVersionID: svid)
        let rec = try #require(snap.dimension(.structuralExtraction))
        await #expect(throws: SourceReadinessError.evidenceChangedDuringMeasurement(.structuralExtraction)) {
            try await r.readiness.apply(SourceReadinessUpdatePlan(
                sourceVersionID: svid, expectedRevision: snap.aggregateRevision,
                updates: [SourceReadinessDimensionUpdate(dimension: .structuralExtraction, state: rec.state, action: .reconcile,
                                                         applicability: rec.applicability, completedUnits: rec.completedUnits,
                                                         totalUnits: rec.totalUnits, basis: rec.basis, detail: rec.detail)],
                producerID: "test", producerVersion: rec.producerVersion, occurredAt: Date(), measuredEvidence: measured))
        }
    }

    @Test("Another source's mutation never stales this source; no change is the fast path")
    func unrelatedSourceAndFastPath() async throws {
        let r = try await rig()
        let a = try await ingest(r, "a.txt")
        let b = try await ingest(r, "b.txt", lead: "Bob reviewed")
        try await r.db.exec("DELETE FROM chunks WHERE rowid = (SELECT MAX(rowid) FROM chunks WHERE source_version_id = ?);", [.uuid(a)])
        for d in [SourceReadinessDimension.indexing, .structuralExtraction, .textExtraction] {
            #expect(try await proofIsCurrent(r, b, d), "\(d) of an untouched source went stale")
        }
        // Fast path: an unchanged source is not re-measured or re-written by reconciliation.
        let before = try await r.readiness.snapshot(sourceVersionID: b).aggregateRevision
        _ = try await r.c.ensureUpgrade(sourceVersionID: b, goal: .evidenceReady, execution: .background)
        #expect(try await r.readiness.snapshot(sourceVersionID: b).aggregateRevision == before)
    }
}
