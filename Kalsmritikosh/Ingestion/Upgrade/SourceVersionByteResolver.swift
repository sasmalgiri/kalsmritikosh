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

public struct SourceVersionByteResolver: Sendable {

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
            SELECT content_hash, custody_mode, vault_address, original_url, detected_type, filename
              FROM source_versions WHERE id = ? LIMIT 1;
            """, [.uuid(sourceVersionID)]).first, let hash = row.string(0) else {
            throw SourceUpgradeError.sourceVersionMissing(sourceVersionID)
        }
        let custody = row.string(1) ?? "referenced"
        let vaultAddress = row.string(2)
        let originalURL = row.string(3)
        let type = SourceType(rawValue: row.string(4) ?? "") ?? .unknown
        let filename = row.string(5) ?? "source"

        let snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usf-upgrade-reopen", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let identity = originalURL.flatMap { URL(string: $0) } ?? URL(fileURLWithPath: filename)

        if custody == "managed" {
            let address = vaultAddress ?? hash
            guard let vault, await vault.contains(address), let blobURL = await vault.url(for: address) else {
                throw SourceUpgradeError.vaultBlobMissing(sourceVersionID)
            }
            let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(byteURL: blobURL, identityURL: identity, snapshotDirectory: snapshotDir)
            guard captured.contentHash.lowercased() == hash.lowercased() else {
                try? FileManager.default.removeItem(at: snapshotDir)
                throw SourceUpgradeError.hashMismatch(sourceVersionID)
            }
            return Resolved(sourceVersionID: sourceVersionID, snapshotURL: snapshotURL, identityURL: identity,
                            contentHash: hash, sourceType: type, cleanupDirectory: snapshotDir)
        }

        // Referenced: re-hash the current file; upgrade only if the exact bytes are unchanged.
        guard let url = originalURL.flatMap({ URL(string: $0) }), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw SourceUpgradeError.sourceUnavailable(sourceVersionID)
        }
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(byteURL: url, identityURL: url, snapshotDirectory: snapshotDir)
        guard captured.contentHash.lowercased() == hash.lowercased() else {
            try? FileManager.default.removeItem(at: snapshotDir)
            throw SourceUpgradeError.sourceBytesChanged(sourceVersionID)
        }
        return Resolved(sourceVersionID: sourceVersionID, snapshotURL: snapshotURL, identityURL: url,
                        contentHash: hash, sourceType: type, cleanupDirectory: snapshotDir)
    }
}
