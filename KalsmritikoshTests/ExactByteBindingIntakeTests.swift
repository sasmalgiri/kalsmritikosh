//
//  ExactByteBindingIntakeTests.swift
//  KalsmritikoshTests
//
//  USF-001.2 — the immutable per-intake processing snapshot binds the loader and structural
//  parser to the EXACT bytes that produced the intake SHA-256. The snapshot is written in the
//  same verified streaming pass as the hash, it is independent of any later mutation of the
//  original, the parser's own hash equals the source version's hash (no foreign-hash
//  substitution), managed custody promotes the snapshot bytes, and the coordinator removes the
//  snapshot after processing. Synthetic sources only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-001.2 — exact-byte binding", .serialized)
struct ExactByteBindingIntakeTests {

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Capture snapshot

    @Test("captureToSnapshot writes a snapshot whose bytes and hash equal the original")
    func snapshotBytesEqualOriginal() async throws {
        let dir = try tempDir()
        let bytes = Data("exact-byte payload — synthetic".utf8)
        let src = dir.appendingPathComponent("doc.txt"); try bytes.write(to: src)
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(src, snapshotDirectory: dir.appendingPathComponent("snap", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(try Data(contentsOf: snapshotURL) == bytes)          // snapshot bytes are the original bytes
        #expect(captured.contentHash == sha256(bytes))               // intake hash is SHA-256 of those bytes
    }

    @Test("The captured content hash is a lowercase 64-char hexadecimal SHA-256")
    func snapshotHashIsHex() async throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("a.txt"); try Data("hello".utf8).write(to: src)
        let (captured, _) = try SourceByteCapture.captureToSnapshot(src, snapshotDirectory: dir.appendingPathComponent("s", isDirectory: true))
        #expect(captured.contentHash.count == 64)
        #expect(captured.contentHash == captured.contentHash.lowercased())
        #expect(captured.contentHash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("The snapshot is independent of a later mutation of the original (parser stays bound to captured bytes)")
    func snapshotIndependentOfLaterMutation() async throws {
        let dir = try tempDir()
        let original = Data("version one — the captured bytes".utf8)
        let src = dir.appendingPathComponent("m.txt"); try original.write(to: src)
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(src, snapshotDirectory: dir.appendingPathComponent("s", isDirectory: true))
        // The original changes AFTER capture — as if edited before the parser reads it.
        try Data("version two — mutated after capture".utf8).write(to: src)
        // The snapshot still holds the captured bytes, and hashing it still yields the intake hash.
        #expect(try Data(contentsOf: snapshotURL) == original)
        #expect(sha256(try Data(contentsOf: snapshotURL)) == captured.contentHash)
    }

    @Test("The snapshot preserves the original filename so filename-derived behaviour is unchanged")
    func snapshotPreservesFilename() async throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("Contract-2025.txt"); try Data("x".utf8).write(to: src)
        let (_, snapshotURL) = try SourceByteCapture.captureToSnapshot(src, snapshotDirectory: dir.appendingPathComponent("s", isDirectory: true))
        #expect(snapshotURL.lastPathComponent == "Contract-2025.txt")
    }

    @Test("captureToSnapshot removes the partial snapshot when capture fails")
    func snapshotRemovedOnFailure() async throws {
        let dir = try tempDir()
        let snapDir = dir.appendingPathComponent("s", isDirectory: true)
        // A directory is not a regular file — capture throws; the snapshot file must not linger.
        await #expect(throws: SourceIntakeError.self) {
            _ = try SourceByteCapture.captureToSnapshot(dir, snapshotDirectory: snapDir)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: snapDir.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: - Managed custody promotes the snapshot bytes

    @Test("Managed custody vaults the exact snapshot bytes under their content address")
    func managedVaultsSnapshotBytes() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytes = USF001Fixtures.bytes("managed via snapshot")
        let url = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: bytes)
        let h = try await USF001Fixtures.intakeWithSnapshot(rig, url: url, custody: .managed)
        #expect(h.preservationStatus == .managedCopyStored)
        #expect(h.vaultAddress == h.contentHash)
        #expect(await rig.vault.data(for: h.contentHash) == bytes)   // the vaulted bytes ARE the captured bytes
    }

    // MARK: - End-to-end: parser hash equals version hash (no override)

    @Test("An end-to-end ingest binds the persisted document + version hash to the intake SHA-256")
    @MainActor func endToEndParserHashEqualsVersionHash() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf12-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(
            database: db, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))))
        let coordinator = IngestCoordinator(
            loaders: .standard(),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            structuralRegistry: .standard(ocr: VisionOCR()),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            intakeCoordinator: intake)

        let text = "Synthetic memo. Parties agreed on 3 March 2025 to proceed."
        let url = dir.appendingPathComponent("memo.txt"); try text.write(to: url, atomically: true, encoding: .utf8)
        let expected = sha256(Data(text.utf8))
        let result = try await coordinator.ingest(fileAt: url)
        let versionID = try #require(result.sourceVersionID)

        // The source version hash equals the intake SHA-256 of the exact bytes on disk.
        let versionHash = try await db.query("SELECT content_hash FROM source_versions WHERE id = ?;", [.uuid(versionID)]).first?.string(0)
        #expect(versionHash == expected)
        #expect(result.fileRecord.contentHash == expected)
        // A structural document attached to that same version (its content hash is pinned to the
        // version by the attach gate — proving the parser hash equalled the version hash).
        let docID = try #require(try await db.query("SELECT document_id FROM source_versions WHERE id = ?;", [.uuid(versionID)]).first?.uuid(0))
        // The persisted document row carries the exact intake hash — no foreign-hash substitution.
        let docHash = try await db.query("SELECT content_hash FROM source_documents WHERE id = ?;", [.uuid(docID)]).first?.string(0)
        #expect(docHash == expected)
    }

    // MARK: - Regression guard: the parser hash is never overwritten

    @Test("The coordinator no longer substitutes a foreign hash onto the parsed document")
    func noForeignHashSubstitution() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repoRoot.appendingPathComponent("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift"), encoding: .utf8)
        // The USF-001.1 override (relabelling the parsed document with the intake hash) is gone.
        #expect(!src.contains("contentHash: h, metadata: parsed.metadata"))
        // The exact-byte mismatch guard (write no artifacts on disagreement) is present.
        #expect(src.contains("Structural parse hash mismatch"))
        // The loader + parser read the immutable snapshot.
        #expect(src.contains("processingSnapshotURL"))
    }
}
