//
//  SourceReprocessingTests.swift
//  KalsmritikoshTests
//
//  USF-FINAL (USF-010) — integrity-preserving recovery + reprocessing. Staleness is detected per exact
//  SourceVersion by comparing a parser-dependent dimension's producer version to the current parser
//  version; reprocessing invalidates ONLY the stale parser dimensions and re-runs the exact-byte
//  structural upgrade, preserving custody + search readiness + unrelated accepted work. Idempotent.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-FINAL — source reprocessing (USF-010)", .serialized)
@MainActor
struct SourceReprocessingTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf010-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        return Rig(c: c, db: db, dir: dir)
    }

    private func writeTxt(_ rig: Rig, _ name: String, _ body: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try body.write(to: url, atomically: true, encoding: .utf8); return url
    }

    /// Simulate that a parser-dependent dimension was produced by an OLDER parser version.
    private func downgrade(_ rig: Rig, _ sv: UUID, _ dim: SourceReadinessDimension) async throws {
        try await rig.db.exec("UPDATE source_readiness_dimensions SET producer_version = '0' WHERE source_version_id = ? AND dimension = ?;",
                             [.uuid(sv), .text(dim.rawValue)])
    }

    @Test("A freshly-ingested source is up to date (nothing to reprocess)")
    func freshIsUpToDate() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "fresh.txt", "Fresh body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        #expect(try await rig.c.reprocess(sourceVersionID: sv) == .upToDate)
    }

    @Test("Staleness is detected only for parser dimensions produced by an older version")
    func staleDetection() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "s.txt", "Stale body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        let repro = SourceReprocessingCoordinator(database: rig.db, readiness: SourceReadinessRepository(database: rig.db),
                                                  byteResolver: SourceVersionByteResolver(database: rig.db, vault: EvidenceVault(root: rig.dir.appendingPathComponent("v2"))))
        let plugin = try await XcodeCurrentParserVersion(rig, sv)
        #expect(try await repro.staleParserDimensions(sourceVersionID: sv, currentParserVersion: plugin).isEmpty)   // fresh → none
        try await downgrade(rig, sv, .structuralExtraction)
        #expect(try await repro.staleParserDimensions(sourceVersionID: sv, currentParserVersion: plugin) == [.structuralExtraction])
    }

    /// The current structural parser version for a source version (the reprocess target).
    private func XcodeCurrentParserVersion(_ rig: Rig, _ sv: UUID) async throws -> String {
        try await rig.db.query("SELECT producer_version FROM source_readiness_dimensions WHERE source_version_id = ? AND dimension = 'metadataExtraction';", [.uuid(sv)]).first?.string(0) ?? "1"
    }

    @Test("A stale parser dimension is reprocessed and converges to up-to-date")
    func staleReprocessConverges() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "c.txt", "Converge body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        let outcome = try await rig.c.reprocess(sourceVersionID: sv, execution: .foreground)
        guard case .reprocessed(let dims) = outcome else { Issue.record("expected reprocessed"); return }
        #expect(dims == [.structuralExtraction])
        #expect(try await rig.c.reprocess(sourceVersionID: sv) == .upToDate)                       // converged
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == true)           // re-evidence-ready
    }

    @Test("Reprocessing preserves search readiness (loader-produced dimensions untouched)")
    func reprocessPreservesSearch() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "p.txt", "Preserve body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        _ = try await rig.c.reprocess(sourceVersionID: sv, execution: .foreground)
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isSearchReady == true)             // search never lost
    }

    @Test("Reprocessing preserves custody (the source version row is untouched)")
    func reprocessPreservesCustody() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "cust.txt", "Custody body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        let before = try await rig.db.query("SELECT content_hash, custody_mode, preservation_status FROM source_versions WHERE id = ?;", [.uuid(sv)]).first
        try await downgrade(rig, sv, .structuralExtraction)
        _ = try await rig.c.reprocess(sourceVersionID: sv, execution: .foreground)
        let after = try await rig.db.query("SELECT content_hash, custody_mode, preservation_status FROM source_versions WHERE id = ?;", [.uuid(sv)]).first
        #expect(before?.string(0) == after?.string(0))
        #expect(before?.string(1) == after?.string(1))
        #expect(before?.string(2) == after?.string(2))
    }

    @Test("A changed referenced source cannot be reprocessed onto the old version")
    func changedBytesBlocksReprocess() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "ch.txt", "Original v1 body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        try "Mutated v2 — entirely different content now.".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await rig.c.reprocess(sourceVersionID: sv, execution: .foreground)
        }
    }

    @Test("Reprocess is a no-op when already up to date (idempotent)")
    func reprocessIdempotent() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "idem.txt", "Idempotent body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        #expect(try await rig.c.reprocess(sourceVersionID: sv) == .upToDate)
        #expect(try await rig.c.reprocess(sourceVersionID: sv) == .upToDate)
    }

    @Test("Reprocess of a missing source version throws")
    func reprocessMissing() async throws {
        let rig = try await makeRig()
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await rig.c.reprocess(sourceVersionID: UUID())
        }
    }
}
