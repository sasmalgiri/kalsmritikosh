//
//  ContainerIngestIntegrationTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (§34) — end-to-end safe container expansion through the real IngestCoordinator pipeline, plus
//  coordinator-level tests for the shared depth / cycle / budget limits (custom policy). Admitted members
//  become managed canonical child SourceVersions with archiveMember provenance; blocked / encrypted /
//  corrupt / unsupported members stay VISIBLE in the manifest; nested archives are bounded globally.
//  Synthetic sources only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-M2 — container ingest integration", .serialized)
@MainActor
struct ContainerIngestIntegrationTests {

    private func makeRig() async throws -> (IngestCoordinator, Database, ContainerInspectionRepository, EvidenceVault) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let containerRepo = ContainerInspectionRepository(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: containerRepo,
            intakeCoordinator: intake)
        return (coordinator, db, containerRepo, vault)
    }

    private func members(_ repo: ContainerInspectionRepository, _ parent: UUID) async throws -> [ContainerMember] {
        try await repo.members(parentSourceVersionID: parent)
    }

    // MARK: - End-to-end expansion

    @Test("A simple ZIP expands its members into admitted child sources with a complete manifest")
    func simpleZipExpands() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "alpha body one, synthetic."),
                                               ZIPTestFixture.stored("b.txt", "bravo body two, synthetic.")], named: "docs.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let manifest = try await repo.manifest(sourceVersionID: parent)
        #expect(manifest?.status == .complete)
        #expect(manifest?.admittedMembers == 2)
        let ms = try await members(repo, parent)
        #expect(ms.filter { $0.disposition == .admitted }.count == 2)
        #expect(ms.filter { $0.disposition == .admitted }.allSatisfy { $0.childSourceVersionID != nil && $0.contentHash != nil })
    }

    @Test("Admitted members become MANAGED canonical child SourceVersions")
    func membersAreManagedChildren() async throws {
        let (c, db, repo, vault) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("note.txt", "managed child body — synthetic.")], named: "one.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let child = try #require(try await members(repo, parent).first { $0.disposition == .admitted }?.childSourceVersionID)
        let custody = try await db.query("SELECT custody_mode, preservation_status FROM source_versions WHERE id = ?;", [.uuid(child)]).first
        #expect(custody?.string(0) == "managed")
        #expect(custody?.string(1) == "managedCopyStored")
        let hash = try #require(try await members(repo, parent).first { $0.disposition == .admitted }?.contentHash)
        #expect(await vault.data(for: hash) != nil)
    }

    @Test("Each admitted member records an exact archiveMember version relation")
    func archiveMemberRelations() async throws {
        let (c, db, _, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "one"), ZIPTestFixture.stored("b.txt", "two")], named: "rel.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let n = try await db.query("SELECT COUNT(*) FROM source_version_relations WHERE parent_source_version_id = ? AND relation = 'archiveMember';", [.uuid(parent)]).first?.int(0)
        #expect(n == 2)
    }

    @Test("An unsafe-path member is blocked and visible, never admitted")
    func unsafePathBlocked() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "../../evil.txt", data: Data("x".utf8)),
                                               ZIPTestFixture.stored("ok.txt", "safe body")], named: "unsafe.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let ms = try await members(repo, parent)
        #expect(ms.contains { $0.disposition == .blockedUnsafePath && $0.childSourceVersionID == nil })
        #expect(ms.filter { $0.disposition == .admitted }.count == 1)
        #expect(try await repo.manifest(sourceVersionID: parent)?.status == .partial)
    }

    @Test("An encrypted member stays visible as encrypted, not empty")
    func encryptedVisible() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "secret.txt", data: Data("locked".utf8), encrypted: true),
                                               ZIPTestFixture.stored("ok.txt", "safe body")], named: "enc.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let ms = try await members(repo, parent)
        #expect(ms.contains { $0.disposition == .encrypted && $0.childSourceVersionID == nil })
        #expect(try await repo.manifest(sourceVersionID: parent)?.status == .partial)
    }

    @Test("A corrupt member fails visibly as failedExtraction")
    func corruptVisible() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([
            ZIPTestFixture.Entry(name: "broken.bin", data: Data(repeating: 7, count: 100), method: 8, corrupt: true, declaredUncompressed: 100),
            ZIPTestFixture.stored("ok.txt", "safe body")], named: "corrupt.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        #expect(try await members(repo, parent).contains { $0.disposition == .failedExtraction })
    }

    @Test("Duplicate member names are both admitted (ordinal disambiguates)")
    func duplicateNames() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("dup.txt", "first distinct body"),
                                               ZIPTestFixture.stored("dup.txt", "second distinct body")], named: "dup.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let admitted = try await members(repo, parent).filter { $0.disposition == .admitted }
        #expect(admitted.count == 2)
        #expect(Set(admitted.map(\.childSourceVersionID)).count == 2)   // two distinct child sources
    }

    @Test("A directory entry is recorded but is not a source")
    func directoryEntry() async throws {
        let (c, _, repo, _) = try await makeRig()
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.directory("sub/"),
                                               ZIPTestFixture.stored("sub/f.txt", "nested body")], named: "dir.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let ms = try await members(repo, parent)
        #expect(ms.contains { $0.disposition == .directory && $0.childSourceVersionID == nil })
        #expect(ms.filter { $0.disposition == .admitted }.count == 1)
        #expect(try await repo.manifest(sourceVersionID: parent)?.regularFileEntries == 1)
    }

    @Test("A nested ZIP is expanded, recording a manifest for each level")
    func nestedZipExpanded() async throws {
        let (c, _, repo, _) = try await makeRig()
        let innerBytes = ZIPTestFixture.build([ZIPTestFixture.stored("leaf.txt", "innermost leaf body — synthetic.")])
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "inner.zip", data: innerBytes, method: 0)], named: "outer.zip")
        let parent = try #require(try await c.ingest(fileAt: zip).sourceVersionID)
        let innerChild = try #require(try await members(repo, parent).first { $0.disposition == .admitted }?.childSourceVersionID)
        // The inner zip has its OWN manifest with the leaf admitted.
        let innerManifest = try await repo.manifest(sourceVersionID: innerChild)
        #expect(innerManifest != nil)
        #expect(innerManifest?.admittedMembers == 1)
    }

    @Test("A RAR file ingested through the full pipeline records an honest-unsupported manifest")
    func rarEndToEnd() async throws {
        let (c, _, repo, _) = try await makeRig()
        var bytes = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]); bytes.append(Data(repeating: 0x11, count: 64))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-rar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("archive.rar"); try bytes.write(to: url)
        let parent = try #require(try await c.ingest(fileAt: url).sourceVersionID)
        let m = try await repo.manifest(sourceVersionID: parent)
        #expect(m?.status == .unsupported)          // recognized, custody kept, contents not enumerated
        #expect(m?.totalEntries == 0)               // unknown ≠ empty
    }

    // MARK: - Bounded limits (coordinator-level, custom policy)

    /// A stub member-ingest that seeds a real child SourceVersion (so the admitted composite FK holds)
    /// and returns its identity — lets us exercise depth/budget limits without the full pipeline.
    private func seedingStub(_ db: Database) -> ContainerProcessingCoordinator.IngestMember {
        { byteURL, origin, _ in
            let id = UUID()
            let hash = ContainerProcessingCoordinator.hashFile(byteURL)
            let type = SourceType.detect(from: origin)
            try? await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                               [.uuid(id), .text(origin.absoluteString), .text(type.rawValue), .text("available")])
            try? await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(id), .text(hash), .real(1), .integer(1), .real(1),
                      .text(origin.lastPathComponent), .text(type.rawValue), .text("magicBytes"), .integer(1),
                      .text("referenced"), .text("referenceRecorded"), .real(1)])
            return .init(childSourceVersionID: id, contentHash: hash, detectedType: type)
        }
    }

    private func seedContainer(_ db: Database, _ id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///c/\(id.uuidString)"), .text("zip"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(String(repeating: "f", count: 64)), .real(1), .integer(1), .real(1),
                  .text("c.zip"), .text("zip"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(1)])
    }

    @Test("Nested depth beyond the policy ceiling blocks the deeper container as blockedDepth")
    func depthLimit() async throws {
        let (_, db, repo, _) = try await makeRig()
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 100, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1 << 30, maxNestingDepth: 1, maxRootTotalMembers: 100,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 100, maxCompressionRatio: 1000)
        let coord = ContainerProcessingCoordinator(repository: repo, policy: policy)
        let innerBytes = ZIPTestFixture.build([ZIPTestFixture.stored("leaf.txt", "leaf")])
        let midBytes = ZIPTestFixture.build([ZIPTestFixture.Entry(name: "inner.zip", data: innerBytes, method: 0)])
        let outer = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "mid.zip", data: midBytes, method: 0)], named: "outer.zip")
        let outerID = UUID(); try await seedContainer(db, outerID)
        await coord.expand(containerVersionID: outerID, containerType: .zip, byteURL: outer,
                           context: .root(sourceVersionID: outerID, containerHash: "outerhash", policy: policy), now: Date(), ingestMember: seedingStub(db))
        // outer → mid admitted; mid → inner.zip blockedDepth.
        let midID = try #require(try await repo.members(parentSourceVersionID: outerID).first { $0.disposition == .admitted }?.childSourceVersionID)
        #expect(try await repo.members(parentSourceVersionID: midID).contains { $0.disposition == .blockedDepth })
    }

    @Test("The nested-container count ceiling blocks extra nested archives")
    func nestedContainerLimit() async throws {
        let (_, db, repo, _) = try await makeRig()
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 100, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1 << 30, maxNestingDepth: 8, maxRootTotalMembers: 100,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 1, maxCompressionRatio: 1000)
        let coord = ContainerProcessingCoordinator(repository: repo, policy: policy)
        let a = ZIPTestFixture.build([ZIPTestFixture.stored("x.txt", "x")])
        let b = ZIPTestFixture.build([ZIPTestFixture.stored("y.txt", "y")])
        let outer = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "a.zip", data: a, method: 0),
                                                 ZIPTestFixture.Entry(name: "b.zip", data: b, method: 0)], named: "outer.zip")
        let outerID = UUID(); try await seedContainer(db, outerID)
        await coord.expand(containerVersionID: outerID, containerType: .zip, byteURL: outer,
                           context: .root(sourceVersionID: outerID, containerHash: "h", policy: policy), now: Date(), ingestMember: seedingStub(db))
        let ms = try await repo.members(parentSourceVersionID: outerID)
        #expect(ms.filter { $0.disposition == .admitted }.count == 1)
        #expect(ms.contains { $0.disposition == .blockedRootBudget })
    }

    @Test("The root member ceiling blocks members beyond the whole-root budget")
    func rootMemberLimit() async throws {
        let (_, db, repo, _) = try await makeRig()
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 100, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1 << 30, maxNestingDepth: 8, maxRootTotalMembers: 1,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 100, maxCompressionRatio: 1000)
        let coord = ContainerProcessingCoordinator(repository: repo, policy: policy)
        let outer = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("a.txt", "a"), ZIPTestFixture.stored("b.txt", "b")], named: "outer.zip")
        let outerID = UUID(); try await seedContainer(db, outerID)
        await coord.expand(containerVersionID: outerID, containerType: .zip, byteURL: outer,
                           context: .root(sourceVersionID: outerID, containerHash: "h", policy: policy), now: Date(), ingestMember: seedingStub(db))
        let ms = try await repo.members(parentSourceVersionID: outerID)
        #expect(ms.filter { $0.disposition == .admitted }.count == 1)
        #expect(ms.contains { $0.disposition == .blockedRootBudget })
    }

    @Test("A nested container whose hash is already an ancestor is blocked as a cycle")
    func cycleBlocked() async throws {
        let (_, db, repo, _) = try await makeRig()
        let innerBytes = ZIPTestFixture.build([ZIPTestFixture.stored("leaf.txt", "leaf")])
        let innerHash = SHA256.hash(data: innerBytes).map { String(format: "%02x", $0) }.joined()
        let outer = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "inner.zip", data: innerBytes, method: 0)], named: "outer.zip")
        let outerID = UUID(); try await seedContainer(db, outerID)
        let coord = ContainerProcessingCoordinator(repository: repo, policy: .standard)
        // Seed the ancestor chain with the inner zip's hash → its appearance is a cycle.
        let ctx = ContainerTraversalContext(rootSourceVersionID: outerID, currentDepth: 0,
                                            ancestorContainerHashes: ["outerhash", innerHash],
                                            budget: ContainerRootBudget(policy: .standard), policy: .standard)
        await coord.expand(containerVersionID: outerID, containerType: .zip, byteURL: outer, context: ctx, now: Date(), ingestMember: seedingStub(db))
        #expect(try await repo.members(parentSourceVersionID: outerID).contains { $0.disposition == .blockedCycle })
    }

    @Test("A RAR container is recorded as honest-unsupported, not empty")
    func rarUnsupported() async throws {
        let (_, db, repo, _) = try await makeRig()
        let id = UUID()
        // Seed a RAR container source version and expand it.
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///r/\(id.uuidString)"), .text("rar"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(String(repeating: "e", count: 64)), .real(1), .integer(1), .real(1),
                  .text("a.rar"), .text("rar"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(1)])
        let coord = ContainerProcessingCoordinator(repository: repo, policy: .standard)
        await coord.expand(containerVersionID: id, containerType: .rar, byteURL: URL(fileURLWithPath: "/nonexistent.rar"),
                           context: .root(sourceVersionID: id, containerHash: "h"), now: Date(), ingestMember: seedingStub(db))
        let m = try await repo.manifest(sourceVersionID: id)
        #expect(m?.status == .unsupported)
        #expect(m?.totalEntries == 0)   // contents unknown ≠ empty
    }
}
