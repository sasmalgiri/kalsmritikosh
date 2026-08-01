//
//  StableMemberIntakeTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (USF-006 §10/§11) — an archive member's BYTES live at a temporary extraction path, but its
//  durable IDENTITY is a stable virtual origin (kalsmritikosh-container://...). Byte capture reads the
//  temp file; detection + filename + the persisted original_url come from the origin. Members use
//  MANAGED custody so their bytes survive after the temp extraction is removed. Synthetic only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-M2 — stable archive-member intake", .serialized)
struct StableMemberIntakeTests {

    private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func tempFile(_ name: String, _ bytes: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name); try bytes.write(to: url); return url
    }

    private func origin(parent: UUID, ordinal: Int, name: String) -> URL {
        URL(string: "kalsmritikosh-container://\(parent.uuidString)/\(ordinal)/\(name)")!
    }

    @Test("Capture reads bytes from the temp file but records identity from the stable origin")
    func captureSeparatesBytesFromIdentity() throws {
        let bytes = Data("synthetic member body — enough words".utf8)
        let byteURL = try tempFile("extracted-0.tmp", bytes)   // mangled temp name
        let origin = origin(parent: UUID(), ordinal: 0, name: "report.txt")
        let snapDir = byteURL.deletingLastPathComponent().appendingPathComponent("snap", isDirectory: true)
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(byteURL: byteURL, identityURL: origin, snapshotDirectory: snapDir)
        #expect(captured.contentHash == sha256(bytes))                 // hash of the temp bytes
        #expect(captured.filename == "report.txt")                     // identity name, not the temp name
        #expect(captured.detectedType == .txt)                         // detected from the origin extension
        #expect(try Data(contentsOf: snapshotURL) == bytes)            // snapshot holds the exact bytes
    }

    @Test("A ZIP-magic member with an origin .docx name is detected as docx, not zip")
    func compoundSubtypeFromOrigin() throws {
        var bytes = Data([0x50, 0x4B, 0x03, 0x04]); bytes.append(Data(repeating: 0, count: 40))
        let byteURL = try tempFile("m-3.bin", bytes)
        let origin = origin(parent: UUID(), ordinal: 3, name: "contract.docx")
        let (captured, _) = try SourceByteCapture.captureToSnapshot(byteURL: byteURL, identityURL: origin,
                                                                    snapshotDirectory: byteURL.deletingLastPathComponent().appendingPathComponent("s"))
        #expect(captured.detectedType == .docx)
    }

    // MARK: - End-to-end managed custody

    private func makeCoordinator() async throws -> (UniversalSourceIntakeCoordinator, Database, EvidenceVault) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let repo = CanonicalSourceIntakeRepository(database: db, vault: vault)
        return (UniversalSourceIntakeCoordinator(repository: repo), db, vault)
    }

    @Test("A member admitted with managed custody vaults its exact bytes under the stable origin identity")
    func memberManagedCustody() async throws {
        let (coordinator, db, vault) = try await makeCoordinator()
        let bytes = Data("Synthetic attachment. Agreed on 3 March 2025.".utf8)
        let byteURL = try tempFile("tmp-member.bin", bytes)
        let parent = UUID()
        let originURL = origin(parent: parent, ordinal: 2, name: "memo.txt")
        let handle = try await coordinator.admit(byteURL: byteURL, originIdentity: originURL, custodyMode: .managed, now: Date())
        #expect(handle.contentHash == sha256(bytes))
        #expect(handle.preservationStatus == .managedCopyStored)
        #expect(handle.detectedType == .txt)
        #expect(await vault.data(for: handle.contentHash) == bytes)
        // The persisted identity is the stable origin, NOT the temp path.
        let originalURL = try await db.query("SELECT original_url FROM source_versions WHERE id = ?;", [.uuid(handle.sourceVersionID)]).first?.string(0)
        #expect(originalURL == originURL.absoluteString)
        #expect(originalURL?.contains("tmp-member") == false)
    }

    @Test("Removing the temp extraction after intake does not affect the managed child bytes")
    func tempRemovalKeepsManagedBytes() async throws {
        let (coordinator, _, vault) = try await makeCoordinator()
        let bytes = Data("managed survives temp removal — synthetic".utf8)
        let byteURL = try tempFile("ephemeral.bin", bytes)
        let handle = try await coordinator.admit(byteURL: byteURL, originIdentity: origin(parent: UUID(), ordinal: 0, name: "x.txt"),
                                                 custodyMode: .managed, now: Date())
        // Delete the entire temp extraction directory.
        try FileManager.default.removeItem(at: byteURL.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: byteURL.path))
        #expect(await vault.data(for: handle.contentHash) == bytes)   // evidence remains reopenable
    }
}
