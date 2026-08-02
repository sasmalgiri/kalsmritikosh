//
//  CanonicalIngestionCompletionTests.swift
//  KalsmritikoshTests
//
//  USF-M3 (USF-008 §37) — the canonical completion contract. Completion state comes ONLY from the
//  readiness authority (never from ingest-attempt status), is exact-version keyed, and distinguishes
//  searchable ≠ evidence-ready ≠ analytical-ready. A superseded version keeps its own historical
//  completion. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M3 — canonical ingestion completion", .serialized)
struct CanonicalIngestionCompletionTests {

    private struct Rig {
        let db: Database
        let readiness: SourceReadinessRepository
        let service: IngestionCompletionService
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm3-comp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let readiness = SourceReadinessRepository(database: db)
        let service = IngestionCompletionService(database: db, readiness: readiness, container: ContainerInspectionRepository(database: db))
        return Rig(db: db, readiness: readiness, service: service)
    }

    private func makeVersion(_ rig: Rig, type: SourceType = .txt, logical: UUID? = nil, current: Bool = true,
                             supersedes: UUID? = nil) async throws -> UUID {
        let id = UUID(); let log = logical ?? id
        try await rig.db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                             [.uuid(id), .text("file:///x/\(id.uuidString)"), .text(type.rawValue), .text("available")])
        try await rig.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, supersedes, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(log), .text(String(repeating: "a", count: 64)), supersedes.map { SQLValue.uuid($0) } ?? .null,
                  .real(100), .integer(current ? 1 : 0), .real(100), .text("f.\(type.rawValue)"), .text(type.rawValue),
                  .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        _ = try await rig.readiness.bootstrap(sourceVersionID: id, detectedType: type, preservationStatus: .referenceRecorded, at: t0)
        return id
    }

    private func apply(_ rig: Rig, _ id: UUID, _ updates: [SourceReadinessDimensionUpdate]) async throws {
        let snap = try await rig.readiness.snapshot(sourceVersionID: id)
        _ = try await rig.readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: id, expectedRevision: snap.aggregateRevision, updates: updates,
            producerID: "test", producerVersion: "1", occurredAt: t0))
    }

    /// Seed `count` real chunks owned by the exact source version so ftsCoverage reports (count, count).
    private func seedChunks(_ rig: Rig, _ id: UUID, _ count: Int) async throws {
        let ko = UUID()
        try await rig.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                             [.uuid(ko), .uuid(id), .text("txt"), .text("body"), .real(0), .real(0)])
        for i in 0..<count {
            try await rig.db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id) VALUES (?,?,?,?,?,?,?,?);",
                                 [.uuid(UUID()), .uuid(ko), .integer(Int64(i)), .text("chunk \(i) searchable"), .integer(0), .integer(10), .real(0), .uuid(id)])
        }
    }

    private func makeSearchable(_ rig: Rig, _ id: UUID) async throws {
        try await seedChunks(rig, id, 5)   // durable FTS coverage the indexing dimension will verify against
        try await apply(rig, id, [
            SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .ready, action: .satisfy, completedUnits: 5, totalUnits: 5),
            SourceReadinessDimensionUpdate(dimension: .indexing, state: .ready, action: .satisfy, completedUnits: 5, totalUnits: 5,
                                           basis: SourceReadinessBasis(kind: .ftsIndex, identifier: id.uuidString))])
    }

    // MARK: - Contract

    @Test("A completed pass that is searchable is NOT evidence-ready")
    func passCompletedNotEvidenceReady() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig); try await makeSearchable(rig, id)
        // An operational attempt row says the pass completed — completion must ignore it.
        try await rig.db.exec("INSERT INTO ingest_file_attempts (id, url, status, attempted_at) VALUES (?,?,?,?);",
                             [.uuid(UUID()), .text("file:///x"), .text("passCompleted"), .real(1)])
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        #expect(c.isSearchReady)
        #expect(!c.isEvidenceReady)
        #expect(c.completionState == .searchablePartial)
    }

    @Test("The completion snapshot mirrors the durable readiness snapshot exactly")
    func completionMirrorsReadiness() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig); try await makeSearchable(rig, id)
        let r = try await rig.readiness.snapshot(sourceVersionID: id)
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        // The service surfaces the readiness authority verbatim — it derives nothing of its own.
        #expect(c.completionState == r.completionState)
        #expect(c.isSearchReady == r.isSearchReady)
        #expect(c.isEvidenceReady == r.isEvidenceReady)
        #expect(c.isAnalyticallyReady == r.isAnalyticallyReady)
        #expect(c.readinessRevision == r.aggregateRevision)
    }

    @Test("A preserved-but-unparsed source reads preservedOnly")
    func preservedOnly() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)   // no text/indexing applied
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        #expect(!c.isSearchReady)
        #expect(c.completionState == .preservedOnly)
    }

    @Test("Deferred media stays deferred")
    func deferredStaysDeferred() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig, type: .mp3)
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        #expect(c.completionState == .deferred)
    }

    @Test("An encrypted source stays encrypted, not empty")
    func encryptedStaysEncrypted() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)
        try await apply(rig, id, [SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .blocked, action: .block, condition: .encrypted)])
        #expect(try await rig.service.snapshot(sourceVersionID: id, at: t0).completionState == .encrypted)
    }

    @Test("A corrupt source stays corrupt")
    func corruptStaysCorrupt() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)
        try await apply(rig, id, [SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .blocked, action: .block, condition: .corrupt)])
        #expect(try await rig.service.snapshot(sourceVersionID: id, at: t0).completionState == .corrupt)
    }

    @Test("An unsupported source stays unsupported")
    func unsupportedStaysUnsupported() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)
        try await apply(rig, id, [SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .unsupported, action: .markUnsupported)])
        #expect(try await rig.service.snapshot(sourceVersionID: id, at: t0).completionState == .unsupported)
    }

    @Test("A failed source stays failed")
    func failedStaysFailed() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)
        try await apply(rig, id, [SourceReadinessDimensionUpdate(dimension: .textExtraction, state: .failed, action: .fail)])
        #expect(try await rig.service.snapshot(sourceVersionID: id, at: t0).completionState == .failed)
    }

    @Test("A searchable source is not analytically ready (analytical never auto-set)")
    func analyticalIndependent() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig); try await makeSearchable(rig, id)
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        #expect(c.isSearchReady)
        #expect(!c.isAnalyticallyReady)   // independent tally — never implied by search
    }

    @Test("Ingest-attempt status can never override readiness-derived completion")
    func attemptStatusCannotOverride() async throws {
        let rig = try await makeRig()
        let id = try await makeVersion(rig)   // preservedOnly
        // Even a passCompleted / legacy queryable attempt row does not make it searchable.
        try await rig.db.exec("INSERT INTO ingest_file_attempts (id, url, status, source_version_id, logical_source_id, attempted_at) VALUES (?,?,?,?,?,?);",
                             [.uuid(UUID()), .text("file:///x"), .text("queryable"), .uuid(id), .uuid(id), .real(1)])
        let c = try await rig.service.snapshot(sourceVersionID: id, at: t0)
        #expect(!c.isSearchReady)
        #expect(c.completionState == .preservedOnly)
    }

    @Test("An alias resolves to its canonical exact version's completion")
    func aliasResolvesCanonical() async throws {
        let rig = try await makeRig()
        let canonical = try await makeVersion(rig); try await makeSearchable(rig, canonical)
        // An alias file points at the canonical file; resolving it must reach the canonical version.
        let aliasFile = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type, content_hash, alias_of, availability) VALUES (?,?,?,?,?,?);",
                             [.uuid(aliasFile), .text("file:///alias"), .text("txt"), .text(String(repeating: "a", count: 64)), .uuid(canonical), .text("available")])
        // Resolve the canonical exact version (files.alias_of → canonical file → its current version).
        let resolved = try #require(try await rig.db.query("""
            SELECT sv.id FROM files f JOIN source_versions sv
              ON sv.id = COALESCE(f.alias_of, f.id) AND sv.is_current = 1 WHERE f.id = ?;
            """, [.uuid(aliasFile)]).first?.uuid(0))
        #expect(resolved == canonical)
        #expect(try await rig.service.snapshot(sourceVersionID: resolved, at: t0).completionState == .searchablePartial)
    }

    @Test("A superseded version retains its own historical completion")
    func supersededRetainsHistorical() async throws {
        let rig = try await makeRig()
        let v1 = try await makeVersion(rig, current: false); try await makeSearchable(rig, v1)   // historical: searchable
        let logical = try #require(try await rig.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(v1)]).first?.uuid(0))
        let v2 = try await makeVersion(rig, logical: logical, current: true, supersedes: v1)     // current: preserved only
        // Each exact version keeps its OWN completion — the newer one does not overwrite the older's.
        #expect(try await rig.service.snapshot(sourceVersionID: v1, at: t0).completionState == .searchablePartial)
        #expect(try await rig.service.snapshot(sourceVersionID: v2, at: t0).completionState == .preservedOnly)
    }

    @Test("A missing source version throws sourceVersionMissing")
    func missingVersion() async throws {
        let rig = try await makeRig()
        await #expect(throws: IngestionCompletionError.self) {
            _ = try await rig.service.snapshot(sourceVersionID: UUID(), at: self.t0)
        }
    }
}
