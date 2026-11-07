//
//  CompanionSnapshot.swift
//  Kalsmritikosh
//
//  W4-6 (Mac side) — a signed, read-only snapshot of the ledger for a future
//  iPhone/iPad viewer. No sync service and no network: the user carries the
//  snapshot folder over (AirDrop, Files, a disk).
//
//    <name>.kalsnapshot/
//      <ledger>.sqlite        consistent copy (SQLite Online Backup, inside the Database actor),
//                             re-encrypted with a passphrase the person sets at export (W2-7)
//      <originals…>           optional: source files, so citations can open on the device
//      kalsnapshot-sources.json  file id → snapshot-relative path of each included original
//      manifest.json          every file's size + SHA-256 (BackupService)
//      signature.json         ECDSA P-256 over SHA-256(manifest.json) with this Mac's key
//
//  `verify` checks the signature AND every file against the manifest; a changed
//  byte anywhere, or a different signer, fails. The iPhone/iPad viewer is the
//  KalsmritikoshViewer target; it asks for the passphrase after verifying.
//

import Foundation
import CryptoKit
import os

nonisolated enum CompanionSnapshotCheck: Sendable, Equatable {
    case valid(fingerprint: String, keyStore: String, files: Int)
    case unsigned
    case badSignature
    case damaged(String)
}

nonisolated enum CompanionSnapshot {
    static let algorithm = "ECDSA-P256-SHA256"
    static let signatureName = "signature.json"

    static func sign(folder: URL) throws {
        guard let key = ConformanceSigningKey.loadOrGenerateBackend() else { throw CocoaError(.featureUnsupported) }
        let manifest = try Data(contentsOf: folder.appendingPathComponent(BackupService.manifestName))
        let digest = Data(SHA256.hash(data: manifest))
        let sig = try key.signature(for: digest)
        let obj: [String: String] = [
            "algorithm": algorithm,
            "manifestSHA256": digest.map { String(format: "%02x", $0) }.joined(),
            "publicKey": key.publicKey.x963Representation.base64EncodedString(),
            "value": sig.derRepresentation.base64EncodedString(),
            "signedAt": ISO8601DateFormatter().string(from: Date()),
            "keyStore": key.assurance
        ]
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent(signatureName))
    }

    static func verify(folder: URL) -> CompanionSnapshotCheck {
        guard let manifest = try? Data(contentsOf: folder.appendingPathComponent(BackupService.manifestName)) else {
            return .damaged("manifest.json is missing")
        }
        guard let sigData = try? Data(contentsOf: folder.appendingPathComponent(signatureName)) else { return .unsigned }
        guard let obj = try? JSONSerialization.jsonObject(with: sigData) as? [String: String],
              obj["algorithm"] == algorithm,
              let keyData = obj["publicKey"].flatMap({ Data(base64Encoded: $0) }),
              let valueData = obj["value"].flatMap({ Data(base64Encoded: $0) }),
              let pub = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: valueData),
              pub.isValidSignature(sig, for: Data(SHA256.hash(data: manifest))) else { return .badSignature }
        guard let (m, verdict) = try? BackupService().inspect(backupFolder: folder) else { return .damaged("manifest.json is unreadable") }
        guard verdict.ok else {
            let names = verdict.corrupt + verdict.missing + verdict.unsafe
            return .damaged("files do not match the manifest: " + names.prefix(5).joined(separator: ", "))
        }
        let fp = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined().prefix(16)
        return .valid(fingerprint: String(fp), keyStore: obj["keyStore"] ?? "unknown", files: m.entries.count)
    }
}

extension AppState {
    /// Shortest passphrase accepted for a snapshot's ledger copy.
    static let minimumSnapshotPassphrase = 8

    /// Write a signed snapshot into `parent`. Returns a plain summary. W2-7 — the ledger copy in the
    /// snapshot is encrypted with `passphrase` (never this Mac's own key); the viewer asks for it.
    func exportCompanionSnapshot(to parent: URL, includeOriginals: Bool, passphrase: String) async throws -> String {
        guard let database else { throw BackupService.BackupError.notADatabaseBackup }
        guard passphrase.count >= Self.minimumSnapshotPassphrase else {
            throw LedgerEncryptionError.conversionFailed("the passphrase must be at least \(Self.minimumSnapshotPassphrase) characters")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = parent.appendingPathComponent("Kalsmritikosh-\(stamp).kalsnapshot", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kalsnap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let consistent = scratch.appendingPathComponent("consistent.sqlite")
        try await StudioStorage.requireAllSaved()   // review R5: no pending studio change left out
        try await database.backupSnapshot(to: consistent)
        let snapshot = scratch.appendingPathComponent(DatabaseLocations.defaultDatabaseURL.lastPathComponent)
        let ledgerKey = database.key
        try await Task.detached { try LedgerCipher.exportCopy(from: consistent, key: ledgerKey, to: snapshot, passphrase: passphrase) }.value
        try? FileManager.default.removeItem(at: consistent)

        // Originals: every readable source file; unreadable ones are counted, not hidden.
        var originals: [(id: UUID, url: URL)] = []
        var unreadable = 0
        var opened: [URL] = []
        if includeOriginals {
            for root in bookmarks.roots { if let u = try? bookmarks.resolve(root) { opened.append(u) } }
            for r in try await database.query("SELECT id, url FROM files;", []) {
                guard let id = r.uuid(0), let url = r.string(1).flatMap(URL.init(string:)) else { continue }
                if FileManager.default.isReadableFile(atPath: url.path) { originals.append((id, url)) } else { unreadable += 1 }
            }
        }
        defer { for u in opened { bookmarks.stopAccessing(u) } }
        let manifest = try BackupService().createBackup(
            databaseURL: snapshot, originalURLs: originals.map(\.url), destination: dest,
            schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970)
        // Rebuild the snapshot-relative names exactly as createBackup assigned them
        // (database first, then originals in order), since the manifest is sorted by path.
        var taken = BackupService.reservedNames
        _ = BackupService.uniqueName(for: snapshot.lastPathComponent, taken: &taken)
        var map: [String: String] = [:]
        for o in originals { map[o.id.uuidString] = BackupService.uniqueName(for: o.url.lastPathComponent, taken: &taken) }
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: dest.appendingPathComponent("kalsnapshot-sources.json"))
        // The sources map is not in the manifest yet: rewrite the manifest to include it, then sign.
        let measured = try BackupService.measure(dest.appendingPathComponent("kalsnapshot-sources.json"))
        let full = BackupPlanner.manifest(schemaVersion: manifest.schemaVersion, createdAtEpoch: manifest.createdAtEpoch,
                                          entries: manifest.entries + [BackupEntry(relativePath: "kalsnapshot-sources.json", byteSize: measured.byteSize,
                                                                                   sha256: measured.sha256, kind: .originalSource)],
                                          coverage: manifest.coverage)
        try JSONEncoder().encode(full).write(to: dest.appendingPathComponent(BackupService.manifestName))
        try CompanionSnapshot.sign(folder: dest)
        return "Signed snapshot “\(dest.lastPathComponent)”: the ledger (encrypted with your passphrase)" + (includeOriginals ? " and \(originals.count) original file(s)" : "")
            + (unreadable > 0 ? "; \(unreadable) original(s) were not readable and are not included" : "") + "."
    }
}
