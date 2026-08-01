//
//  CaseCoverageManifestTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (USF-007 §35) — the deterministic Case Coverage Manifest reconstructed from the existing
//  authorities. Direct roots + archive descendants are covered; derivedConversion is not double-counted;
//  a source reached by several paths is counted once; unadmitted / not-inspected members stay visible;
//  removing a workspace source changes coverage without deleting evidence; generation performs no write
//  and is deterministic. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — case coverage manifest", .serialized)
@MainActor
struct CaseCoverageManifestTests {

    private struct Rig {
        let coordinator: IngestCoordinator
        let db: Database
        let builder: CaseCoverageManifestBuilder
    }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: intake)
        let builder = CaseCoverageManifestBuilder(
            repository: CaseCoverageRepository(database: db), readiness: SourceReadinessRepository(database: db),
            container: ContainerInspectionRepository(database: db))
        return Rig(coordinator: coordinator, db: db, builder: builder)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWorkspace(_ db: Database) async throws -> UUID {
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Case"), .real(1000), .real(1000)])
        return ws
    }
    private func addSource(_ db: Database, _ ws: UUID, fileID: UUID, at: Double = 1000) async throws {
        try await db.exec("INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);",
                          [.uuid(ws), .uuid(fileID), .real(at)])
    }

    // MARK: - Closure

    @Test("Direct roots + archive descendants are covered from a single workspace source")
    func rootsAndDescendants() async throws {
        let rig = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "alpha body"), ZIPTestFixture.stored("b.txt", "bravo body")], named: "case.zip")
        let r = try await rig.coordinator.ingest(fileAt: zip)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(m.summary.directRoots == 1)
        #expect(m.canonicalSources.count == 3)                       // zip + 2 members
        #expect(m.summary.containerMembersAdmitted == 2)
        #expect(m.canonicalSources.contains { $0.isDirectRoot && $0.sourceType == .zip })
    }

    @Test("A converted (derivedConversion) child is NOT counted as an independent case source")
    func derivedConversionNotCounted() async throws {
        let rig = try await makeRig()
        let txt = try writeText(rig, "plain.txt", "root body one")
        let r = try await rig.coordinator.ingest(fileAt: txt)
        let root = try #require(r.sourceVersionID)
        // Seed a converted version + a derivedConversion relation.
        let conv = UUID(); try await seedVersion(rig.db, conv, "pdf")
        try await rig.db.exec("INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, created_at) VALUES (?,?,?,?,?);",
                             [.uuid(UUID()), .uuid(root), .uuid(conv), .text("derivedConversion"), .real(1)])
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(!m.canonicalSources.contains { $0.sourceVersionID == conv })
        #expect(m.canonicalSources.count == 1)
    }

    @Test("A source reachable via several paths is counted once with multiple occurrences")
    func sharedSourceCountedOnce() async throws {
        let rig = try await makeRig()
        // Two zips each containing a byte-identical member → dedup to ONE canonical child.
        let shared = "identical shared attachment body — synthetic."
        let z1 = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("shared.txt", shared)], named: "one.zip")
        let z2 = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("shared.txt", shared)], named: "two.zip")
        let r1 = try await rig.coordinator.ingest(fileAt: z1)
        let r2 = try await rig.coordinator.ingest(fileAt: z2)
        let ws = try await makeWorkspace(rig.db)
        try await addSource(rig.db, ws, fileID: r1.fileRecord.id)
        try await addSource(rig.db, ws, fileID: r2.fileRecord.id, at: 1001)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        // Unique canonical sources < total occurrences (the shared child is reached twice).
        #expect(Set(m.canonicalSources.map(\.sourceVersionID)).count == m.canonicalSources.count)   // no dup rows
        #expect(m.summary.sourceOccurrences > m.summary.canonicalSources)
        #expect(m.canonicalSources.contains { $0.parentPaths.count >= 2 })                            // the shared child
    }

    // MARK: - Visibility

    @Test("Unadmitted (encrypted) container members stay visible in coverage")
    func unadmittedVisible() async throws {
        let rig = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "secret.txt", data: Data("x".utf8), encrypted: true),
                                               ZIPTestFixture.stored("ok.txt", "safe body")], named: "enc.zip")
        let r = try await rig.coordinator.ingest(fileAt: zip)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(m.unadmittedContainerMembers.contains { $0.disposition == .encrypted })
        #expect(m.summary.containerMembersNotAdmitted >= 1)
    }

    @Test("An archive with no v87 manifest reads as not-inspected, never 0 members")
    func notInspectedLimitation() async throws {
        let rig = try await makeRig()
        // Seed a bare zip source version + file with NO container manifest, and add it to a workspace.
        let id = UUID(); let hash = String(repeating: "d", count: 64)
        try await rig.db.exec("INSERT INTO files (id, url, source_type, content_hash, availability) VALUES (?,?,?,?,?);",
                             [.uuid(id), .text("file:///legacy/\(id.uuidString)"), .text("zip"), .text(hash), .text("available")])
        try await seedVersion(rig.db, id, "zip", hash: hash, logical: id)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: id)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(m.limitations.contains { $0.contains("not been inspected") })
    }

    @Test("Search/evidence/analytical counts are independent, not one percentage")
    func independentCounts() async throws {
        let rig = try await makeRig()
        let txt = try writeText(rig, "doc.txt", "searchable synthetic body with several words.")
        let r = try await rig.coordinator.ingest(fileAt: txt)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        let m = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(m.summary.searchable >= 1)
        // Independent tallies — evidence/analytical are their OWN counts (not derived from searchable).
        #expect(m.summary.evidenceReady <= m.summary.canonicalSources)
        #expect(m.summary.analyticallyReady <= m.summary.canonicalSources)
    }

    // MARK: - Membership + determinism + safety

    @Test("Removing a workspace source changes coverage without deleting evidence")
    func removalChangesCoverageNotEvidence() async throws {
        let rig = try await makeRig()
        let txt = try writeText(rig, "keep.txt", "body to keep")
        let r = try await rig.coordinator.ingest(fileAt: txt)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        #expect(try await rig.builder.build(workspaceID: ws, generatedAt: t0).canonicalSources.count == 1)
        try await rig.db.exec("DELETE FROM workspace_sources WHERE workspace_id = ?;", [.uuid(ws)])
        let after = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(after.canonicalSources.isEmpty)
        // Evidence untouched — the source version still exists.
        let sv = try #require(r.sourceVersionID)
        #expect(try await rig.db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(sv)]).first != nil)
    }

    @Test("Manifest generation performs no write")
    func noWriteOnGenerate() async throws {
        let rig = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "a"), ZIPTestFixture.Entry(name: "e.txt", data: Data("e".utf8), encrypted: true)], named: "w.zip")
        let r = try await rig.coordinator.ingest(fileAt: zip)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        func rowCounts() async throws -> (Int64, Int64, Int64) {
            let a = try await rig.db.query("SELECT COUNT(*) FROM container_members;", []).first?.int(0) ?? 0
            let b = try await rig.db.query("SELECT COUNT(*) FROM workspace_sources;", []).first?.int(0) ?? 0
            let c = try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) ?? 0
            return (a, b, c)
        }
        let before = try await rowCounts()
        _ = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        _ = try await rig.builder.build(workspaceID: ws, generatedAt: t0)
        #expect(try await rowCounts() == before)
    }

    @Test("Two builds of the same state are identical apart from generatedAt")
    func deterministic() async throws {
        let rig = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "a body"), ZIPTestFixture.stored("b.txt", "b body")], named: "d.zip")
        let r = try await rig.coordinator.ingest(fileAt: zip)
        let ws = try await makeWorkspace(rig.db); try await addSource(rig.db, ws, fileID: r.fileRecord.id)
        let m1 = try await rig.builder.build(workspaceID: ws, generatedAt: Date(timeIntervalSince1970: 1))
        let m2 = try await rig.builder.build(workspaceID: ws, generatedAt: Date(timeIntervalSince1970: 2))
        #expect(m1.canonicalSources == m2.canonicalSources)
        #expect(m1.unadmittedContainerMembers == m2.unadmittedContainerMembers)
        #expect(m1.summary == m2.summary)
        #expect(m1.generatedAt != m2.generatedAt)
    }

    @Test("An unknown workspace throws workspaceNotFound")
    func unknownWorkspace() async throws {
        let rig = try await makeRig()
        await #expect(throws: CaseCoverageError.self) {
            _ = try await rig.builder.build(workspaceID: UUID(), generatedAt: self.t0)
        }
    }

    // MARK: - Seed helpers

    private func writeText(_ rig: Rig, _ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-txt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name); try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedVersion(_ db: Database, _ id: UUID, _ type: String, hash: String? = nil, logical: UUID? = nil) async throws {
        let h = hash ?? String(repeating: "c", count: 64)
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical ?? id), .text(h), .real(1), .integer(1), .real(1),
                  .text("f.\(type)"), .text(type), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(1)])
    }
}
