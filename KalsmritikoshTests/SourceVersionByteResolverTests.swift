//
//  SourceVersionByteResolverTests.swift
//  KalsmritikoshTests
//
//  USF-M3 (USF-009 §18/§39) — exact-byte reopening for on-demand upgrades. A managed version reopens its
//  verified vault blob; a referenced version re-hashes the current file and upgrades ONLY if unchanged.
//  A changed referenced file cannot mutate the old version (sourceBytesChanged); a missing source is
//  unavailable; a missing vault blob is reported. Synthetic only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-M3 — source-version byte resolver", .serialized)
struct SourceVersionByteResolverTests {

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private struct Rig { let db: Database; let vault: EvidenceVault; let intake: UniversalSourceIntakeCoordinator; let resolver: SourceVersionByteResolver; let dir: URL }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm3-byte-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        return Rig(db: db, vault: vault, intake: intake, resolver: SourceVersionByteResolver(database: db, vault: vault), dir: dir)
    }

    private func writeFile(_ rig: Rig, _ name: String, _ bytes: Data) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try bytes.write(to: url); return url
    }

    @Test("A managed version reopens its exact vault bytes")
    func managedReopensVaultBytes() async throws {
        let rig = try await makeRig()
        let bytes = Data("managed exact bytes — synthetic".utf8)
        let url = try writeFile(rig, "m.txt", bytes)
        let handle = try await rig.intake.admit(url: url, custodyMode: .managed, now: Date())
        let resolved = try await rig.resolver.resolve(sourceVersionID: handle.sourceVersionID, at: Date())
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        #expect(resolved.contentHash == handle.contentHash)
        #expect(try Data(contentsOf: resolved.snapshotURL) == bytes)
    }

    @Test("A referenced version whose file is unchanged resolves to a matching snapshot")
    func referencedUnchangedResolves() async throws {
        let rig = try await makeRig()
        let bytes = Data("referenced unchanged body".utf8)
        let url = try writeFile(rig, "r.txt", bytes)
        let handle = try await rig.intake.admit(url: url, custodyMode: .referenced, now: Date())
        let resolved = try await rig.resolver.resolve(sourceVersionID: handle.sourceVersionID, at: Date())
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        #expect(try Data(contentsOf: resolved.snapshotURL) == bytes)
    }

    @Test("A changed referenced file cannot mutate the old version (sourceBytesChanged)")
    func referencedChangedBlocked() async throws {
        let rig = try await makeRig()
        let url = try writeFile(rig, "c.txt", Data("original v1 bytes".utf8))
        let handle = try await rig.intake.admit(url: url, custodyMode: .referenced, now: Date())
        try Data("mutated v2 bytes — different".utf8).write(to: url)   // the file changed on disk
        await #expect(throws: SourceUpgradeError.sourceBytesChanged(handle.sourceVersionID)) {
            _ = try await rig.resolver.resolve(sourceVersionID: handle.sourceVersionID, at: Date())
        }
    }

    @Test("A missing referenced source is unavailable")
    func missingReferencedUnavailable() async throws {
        let rig = try await makeRig()
        let url = try writeFile(rig, "gone.txt", Data("to be deleted".utf8))
        let handle = try await rig.intake.admit(url: url, custodyMode: .referenced, now: Date())
        try FileManager.default.removeItem(at: url)
        await #expect(throws: SourceUpgradeError.sourceUnavailable(handle.sourceVersionID)) {
            _ = try await rig.resolver.resolve(sourceVersionID: handle.sourceVersionID, at: Date())
        }
    }

    @Test("A missing managed vault blob is reported")
    func vaultBlobMissing() async throws {
        let rig = try await makeRig()
        let bytes = Data("vaulted then removed".utf8)
        let url = try writeFile(rig, "v.txt", bytes)
        let handle = try await rig.intake.admit(url: url, custodyMode: .managed, now: Date())
        if let blob = await rig.vault.url(for: handle.contentHash) { try FileManager.default.removeItem(at: blob) }
        await #expect(throws: SourceUpgradeError.vaultBlobMissing(handle.sourceVersionID)) {
            _ = try await rig.resolver.resolve(sourceVersionID: handle.sourceVersionID, at: Date())
        }
    }

    @Test("A missing source version throws")
    func missingVersion() async throws {
        let rig = try await makeRig()
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await rig.resolver.resolve(sourceVersionID: UUID(), at: Date())
        }
    }
}
