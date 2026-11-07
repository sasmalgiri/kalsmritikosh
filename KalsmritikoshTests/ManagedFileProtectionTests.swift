//
//  ManagedFileProtectionTests.swift
//  KalsmritikoshTests
//
//  K11 — the app-managed files beside the ledger are protected by default: the vector cache is
//  written only sealed (AES-GCM, key derived from the ledger key), is never opened without that
//  key, and is rebuilt rather than trusted when it cannot be opened; vault copies are owner-only.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("Managed file protection (K11)")
struct ManagedFileProtectionTests {

    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("k11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func builtIndex() async throws -> (HNSWVectorIndex, Int) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        let store = SQLiteVectorStore(database: db, modelID: "apple.nl.v1")
        for i in 0..<20 {
            try await store.upsert(chunkID: UUID(), embedding: (0..<8).map { Float(($0 + i) % 5) + 0.5 })
        }
        let index = HNSWVectorIndex()
        _ = await index.build(from: store)
        return (index, 20)
    }

    @Test("The vector cache is sealed on disk, opens only with its key, and is never written without one")
    func sealedCache() async throws {
        let (index, count) = try await builtIndex()
        let dir = try scratch()
        let url = dir.appendingPathComponent("hnsw-index.bin")
        let ledger = LedgerKey.random()
        let key = ledger.derivedKey(for: "hnsw-cache")
        #expect(key != SymmetricKey(data: ledger.raw), "the cache key is derived, not the ledger key")

        // No key: nothing is written.
        #expect(await index.persist(to: url, sealedWith: nil) == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        #expect(await index.persist(to: url, sealedWith: key))
        let bytes = try Data(contentsOf: url)
        // In the clear the file would begin with the magic "HNSW" (little-endian 57 53 4E 48).
        #expect(bytes.prefix(4) != Data([0x57, 0x53, 0x4E, 0x48]), "the cache is not written in the clear")
        #expect(throws: Never.self) { _ = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key) }
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        #expect(await HNSWVectorIndex().load(from: url, expectedCount: count, sealedWith: key))
        #expect(await HNSWVectorIndex().load(from: url, expectedCount: count, sealedWith: LedgerKey.random().derivedKey(for: "hnsw-cache")) == false,
                "another ledger's key does not open it")
        #expect(await HNSWVectorIndex().load(from: url, expectedCount: count, sealedWith: nil) == false)

        // An older, unsealed cache is not trusted (rebuilt from the ledger instead).
        try Data("HNSW plaintext cache from an older build".utf8).write(to: url)
        #expect(await HNSWVectorIndex().load(from: url, expectedCount: count, sealedWith: key) == false)
    }

    @Test("Vault copies are owner-only; copies stored by an older build are tightened once")
    func vaultOwnerOnly() async throws {
        let root = try scratch().appendingPathComponent("EvidenceVault", isDirectory: true)
        let vault = EvidenceVault(root: root)
        let hash = try await vault.store(Data("a letter".utf8))
        let file = try #require(await vault.url(for: hash))
        func perms(_ u: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int }
        #expect(try perms(file) == 0o400)
        #expect(try perms(file.deletingLastPathComponent()) == 0o700)
        #expect(await vault.data(for: hash) == Data("a letter".utf8), "the owner still reads it")

        // An older copy: world-readable file and folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await vault.protectExisting()
        #expect(try perms(file) == 0o400 && perms(root) == 0o700)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".owner-only-v1").path))
        try await vault.remove(hash)
        #expect(await vault.contains(hash) == false, "an owner-only copy can still be removed by an explicit erase")
    }
}
