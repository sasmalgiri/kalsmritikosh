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
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .referenced)
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

    /// A "parser v2" document for the version's exact identity: the committed blocks with changed text.
    private func v2Document(_ rig: Rig, _ sv: UUID, committed: [EvidenceBlock],
                            status: ExtractionStatus = .complete) async throws -> ParsedDocument {
        let row = try #require(try await rig.db.query("SELECT logical_source_id, content_hash FROM source_versions WHERE id = ?;",
                                                      [.uuid(sv)]).first)
        return ParsedDocument(id: UUID(), logicalSourceID: try #require(row.uuid(0)), sourceVersionID: sv, filename: "v2.txt",
                              detectedType: .txt, contentHash: row.string(1) ?? "",
                              blocks: committed.map { b in
                                  EvidenceBlock(documentID: b.documentID, ordinal: b.ordinal, kind: b.kind,
                                                rawText: b.rawText + " (v2 split)", locator: b.locator)
                              }, extractionStatus: status)
    }

    private func coordinator(_ rig: Rig, _ doc: ParsedDocument) -> SourceReprocessingCoordinator {
        SourceReprocessingCoordinator(
            database: rig.db, readiness: SourceReadinessRepository(database: rig.db),
            byteResolver: SourceVersionByteResolver(database: rig.db, vault: EvidenceVault(root: rig.dir.appendingPathComponent("vault", isDirectory: true))),
            reparse: { _, _, _ in doc })
    }

    private func structuralRecord(_ rig: Rig, _ sv: UUID) async throws -> (version: String?, basis: String?, completed: Int?) {
        let r = try await rig.db.query("""
            SELECT producer_version, basis_identifier, completed_units FROM source_readiness_dimensions
             WHERE source_version_id = ? AND dimension = 'structuralExtraction';
            """, [.uuid(sv)]).first
        return (r?.string(0), r?.string(1), r?.int(2).map(Int.init))
    }

    @Test("F16 — a changed parser output is staged, activated atomically, and only then stamped; old blocks stay citable")
    func changedParserOutputActivated() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "v2.txt", "Version two body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        let store = EvidenceStore(database: rig.db)
        let committed = try await store.blocks(forVersion: sv)
        #expect(!committed.isEmpty)
        let v2 = coordinator(rig, try await v2Document(rig, sv, committed: committed))
        let staleBefore = try await v2.staleParserDimensions(sourceVersionID: sv, currentParserVersion: "2")
        #expect(staleBefore.contains(.structuralExtraction))

        let outcome = try await v2.reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date())
        #expect(outcome == .activated(dimensions: staleBefore, supersededBlocks: committed.count, activatedBlocks: committed.count))

        // The version's structure IS v2's output now.
        let active = try await store.blocks(forVersion: sv)
        #expect(active.count == committed.count)
        #expect(active.allSatisfy { $0.rawText.hasSuffix(" (v2 split)") })
        #expect(Set(active.map(\.id)).isDisjoint(with: committed.map(\.id)))
        // The old blocks are superseded, never deleted: a citation naming one still resolves.
        #expect(Set(try await store.supersededBlocks(forVersion: sv).map(\.id)) == Set(committed.map(\.id)))
        #expect(try await store.blocks(ids: committed.map(\.id)).count == committed.count)
        // Ownership carried over: every new block resolves to the version's object.
        let resolutions = try await store.resolveCanonicalBlocks(active.map(\.id))
        #expect(resolutions.allSatisfy { if case .resolved = $0 { return true } else { return false } })
        // Block search sees only the active derivation.
        let hits = try await store.searchBlocks("synthetic structure")
        #expect(!hits.isEmpty && hits.allSatisfy { h in active.contains { $0.id == h.id } })
        // Stamped from the NEW run's committed receipt, and converged.
        let rec = try await structuralRecord(rig, sv)
        #expect(rec.version == "2")
        #expect(rec.basis == (try await store.activatedDerivationReceipt(forVersion: sv))?.parserRunID.uuidString)
        #expect(try await v2.staleParserDimensions(sourceVersionID: sv, currentParserVersion: "2").isEmpty)
        #expect(try await v2.reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date()) == .upToDate)
    }

    @Test("F16 — a changed output that is worse (complete → partial) is refused: nothing activated, still stale")
    func worseOutputRefused() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "worse.txt", "Worse body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        let store = EvidenceStore(database: rig.db)
        let committed = try await store.blocks(forVersion: sv)
        let v2 = coordinator(rig, try await v2Document(rig, sv, committed: committed, status: .partial))
        let staleBefore = try await v2.staleParserDimensions(sourceVersionID: sv, currentParserVersion: "2")
        let outcome = try await v2.reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date())
        guard case .changedOutputRejected(let dims, _) = outcome else { Issue.record("expected rejection, got \(outcome)"); return }
        #expect(dims == staleBefore)
        #expect(try await store.blocks(forVersion: sv).map(\.id) == committed.map(\.id))
        #expect(try await store.supersededBlocks(forVersion: sv).isEmpty)
        #expect(try await structuralRecord(rig, sv).version == "0")
    }

    @Test("F16 — a failed activation leaves nothing half-active; an interrupted stamp resumes from the ACTIVE derivation")
    func interruptionNeverStampsFalsely() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "int.txt", "Interrupted body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        let store = EvidenceStore(database: rig.db)
        let committed = try await store.blocks(forVersion: sv)
        let doc = try await v2Document(rig, sv, committed: committed)

        // 1. An activation that fails part-way (identity gate) rolls back whole.
        let wrong = ParsedDocument(id: UUID(), logicalSourceID: doc.logicalSourceID, sourceVersionID: sv, filename: "v2.txt",
                                   detectedType: .txt, contentHash: String(repeating: "0", count: 64), blocks: doc.blocks)
        await #expect(throws: (any Error).self) {
            _ = try await store.activateDerivation(wrong, parser: "p", parserVersion: "2", startedAt: Date())
        }
        #expect(try await store.blocks(forVersion: sv).map(\.id) == committed.map(\.id))
        #expect(try await store.supersededBlocks(forVersion: sv).isEmpty)

        // 2. Activation commits, then the process dies before the readiness stamp.
        let activation = try await store.activateDerivation(doc, parser: "p", parserVersion: "2", startedAt: Date())
        let before = try await structuralRecord(rig, sv)
        #expect(before.version == "0")                                             // never falsely v2
        #expect(before.basis != activation.receipt.parserRunID.uuidString)

        // 3. The rerun stamps from the ACTIVE derivation's receipt — not the proof it replaced.
        let outcome = try await coordinator(rig, doc).reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date())
        guard case .activated = outcome else { Issue.record("expected resumed activation, got \(outcome)"); return }
        let after = try await structuralRecord(rig, sv)
        #expect(after.version == "2")
        #expect(after.basis == activation.receipt.parserRunID.uuidString)
        #expect(after.completed == activation.receipt.locatedSubstantiveBlockCount)
        #expect(try await coordinator(rig, doc).reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date()) == .upToDate)
    }

    @Test("F16 — a reprocessor with no parser wired refuses to stamp")
    func noReparserRefuses() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "np.txt", "No parser body — synthetic, several words for structure.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        try await downgrade(rig, sv, .structuralExtraction)
        let bare = SourceReprocessingCoordinator(
            database: rig.db, readiness: SourceReadinessRepository(database: rig.db),
            byteResolver: SourceVersionByteResolver(database: rig.db, vault: EvidenceVault(root: rig.dir.appendingPathComponent("vault", isDirectory: true))))
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await bare.reprocess(sourceVersionID: sv, currentParserVersion: "2", at: Date())
        }
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
