//
//  SourceVersionByteResolver.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009 §18) — reopens the EXACT bytes of an exact source version into a temporary immutable
//  processing snapshot, or returns a typed blocker. On-demand upgrade work must NEVER parse whatever
//  bytes happen to exist today and attach them to an older version: a managed version reopens its
//  verified vault blob; a referenced version re-hashes the current file and upgrades ONLY when the hash
//  still equals the version's hash. A changed referenced file yields `sourceBytesChanged` (ingest it as a
//  NEW version); a missing source yields `sourceUnavailable`. The old version's evidence is never mutated
//  with unverified bytes.
//

import Foundation
import os

public nonisolated struct SourceVersionByteResolver: Sendable {

    private let database: Database
    private let vault: EvidenceVault?

    public init(database: Database, vault: EvidenceVault?) {
        self.database = database
        self.vault = vault
    }

    /// A reopened exact-byte snapshot. The caller owns `cleanupDirectory` and removes it after use.
    public struct Resolved: Sendable {
        public let sourceVersionID: UUID
        public let snapshotURL: URL
        public let identityURL: URL
        public let contentHash: String
        public let sourceType: SourceType
        public let cleanupDirectory: URL
    }

    public func resolve(sourceVersionID: UUID, at now: Date) async throws -> Resolved {
        guard let row = try await database.query("""
            SELECT content_hash, custody_mode, vault_address, original_url, detected_type, filename, acquisition_limitation
              FROM source_versions WHERE id = ? LIMIT 1;
            """, [.uuid(sourceVersionID)]).first, let hash = row.string(0) else {
            throw SourceUpgradeError.sourceVersionMissing(sourceVersionID)
        }
        // F03 — an acquisition that never preserved its whole source cannot be reopened as its state.
        guard row.string(6) == nil else { throw SourceUpgradeError.acquisitionIncomplete(sourceVersionID) }
        let custody = row.string(1) ?? "referenced"
        let vaultAddress = row.string(2)
        let originalURL = row.string(3)
        let type = SourceType(rawValue: row.string(4) ?? "") ?? .unknown
        let filename = row.string(5) ?? "source"

        // ALCOA ALC-15 — the reopened exact bytes are staged owner-only in the vault staging area.
        let snapshotDir = try SecureStaging.makeDirectory("reopen-")
        let identity = originalURL.flatMap { URL(string: $0) } ?? URL(fileURLWithPath: filename)

        // Speed PERF-39 torrent (owner 2026-11-23) — not tested yet: the fastest available copy of exactly these bytes —
        // the vault copy or the original — tried in speed order (vault first when the original's disk is slower or
        // unplugged); every copy is hashed while it is captured and used ONLY when it equals the recorded hash.
        let managed = custody == "managed"
        let original = originalURL.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0 : nil }
        let address = (vaultAddress ?? hash).lowercased()
        // A referenced version may still have its bytes in the vault (the same bytes kept for another version).
        let order = await FastestCopy.order(original: original, vault: vault, address: address,
                                            preferOriginalOnTie: !managed)
        var originalChanged = false
        for origin in order {
            let byteURL: URL
            switch origin {
            case .vault:
                guard let vault else { continue }
                // ALCOA ALC-04/05 — the vault copy is re-hashed as it is opened; a mismatch is refused and recorded.
                let opened = await vault.checkedURL(for: address)
                if opened.check == .mismatch {
                    await CustodyRepository.recordForVersions(database, versions: [sourceVersionID], kind: .hashMismatch, actor: nil,
                                                              detail: "reprocessing re-read of the kept copy; SHA-256 does not match — not used")
                }
                guard let blob = opened.url else { continue }
                byteURL = blob
            case .original:
                guard let original, FileManager.default.fileExists(atPath: original.path) else { continue }
                byteURL = original
            }
            let idURL = managed ? identity : (original ?? identity)
            let captured: CapturedSource, snapshotURL: URL
            do {
                (captured, snapshotURL) = try await VolumeReadLanes.withRead(byteURL) {
                    try SourceByteCapture.captureToSnapshot(byteURL: byteURL, identityURL: idURL, snapshotDirectory: snapshotDir)
                }
            } catch {
                KalsmritikoshLog.ingestion.error("SourceVersionByteResolver: the \(origin.rawValue, privacy: .public) copy could not be read: \(error.localizedDescription, privacy: .private)")
                continue
            }
            guard captured.contentHash.lowercased() == hash.lowercased() else {
                SecureStaging.remove(snapshotDir)
                if origin == .original { originalChanged = true }
                await CustodyRepository.recordForVersions(database, versions: [sourceVersionID], kind: .hashMismatch, actor: nil,
                                                          detail: "reprocessing re-read of the \(origin == .vault ? "kept copy" : "original file"); SHA-256 does not match — not used")
                KalsmritikoshLog.ingestion.error("SourceVersionByteResolver: the \(origin.rawValue, privacy: .public) copy does not match the version's hash — not used")
                continue
            }
            await CustodyRepository.recordForVersions(database, versions: [sourceVersionID], kind: .hashVerified, actor: nil,
                                                      detail: "reprocessing re-read of the \(origin == .vault ? "kept copy" : "original file"); SHA-256 re-checked")
            SecureStaging.restrict(snapshotDir)   // ALCOA ALC-15 — folder 0700, file 0600
            return Resolved(sourceVersionID: sourceVersionID, snapshotURL: snapshotURL, identityURL: idURL,
                            contentHash: hash, sourceType: type, cleanupDirectory: snapshotDir)
        }
        SecureStaging.remove(snapshotDir)
        if managed {
            throw order.contains(.vault) ? SourceUpgradeError.hashMismatch(sourceVersionID)
                                         : SourceUpgradeError.vaultBlobMissing(sourceVersionID)
        }
        if originalChanged { throw SourceUpgradeError.sourceBytesChanged(sourceVersionID) }
        throw SourceUpgradeError.sourceUnavailable(sourceVersionID)
    }
}
