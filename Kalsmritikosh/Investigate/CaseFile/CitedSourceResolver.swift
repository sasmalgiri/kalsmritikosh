//
//  CitedSourceResolver.swift
//  Kalsmritikosh
//
//  SRC-01 / SRC-08 — open the CITED version of a source, never silently a newer one. A citation pins a
//  source version (its content hash). The document's file on disk is whatever is there now: it may have
//  been replaced by a newer version (re-ingested: the cited version is superseded) or edited since it
//  was read (not yet re-ingested). Opening "the object's file" would then show different words under
//  the citation. This resolver opens:
//    • the vault's kept copy of the cited version, when there is one (labelled "A newer version exists"
//      when the cited version is no longer current);
//    • the file on disk only when its bytes ARE the cited version (SHA-256 equal to the version's hash);
//  and otherwise says why the cited version is unavailable — superseded, changed on disk, missing, or
//  erased — so the caller shows the cited passage from the ledger with that label instead.
//

import Foundation
import CryptoKit
import os

public nonisolated enum CitedSourceResolver {

    public enum Unavailable: Equatable, Sendable {
        /// The version record is gone (erased).
        case erased
        /// A newer version replaced it and the cited bytes were not kept.
        case superseded
        /// The file on disk is no longer the cited bytes (edited or replaced since it was read).
        case changedOnDisk
        /// The file is not where it was, and no copy was kept.
        case missingOriginal

        public var label: String {
            switch self {
            case .erased: return "Cited version unavailable: it was erased. Only what the ledger still holds is shown."
            case .superseded: return "Cited version unavailable: a newer version of this document exists and the cited version's file was not kept. The cited passage is shown from the ledger, not the newer document."
            case .changedOnDisk: return "Cited version unavailable: the file has changed since it was cited, so it is not opened in its place. The cited passage is shown from the ledger."
            case .missingOriginal: return "Cited version unavailable: the original file is missing and no copy was kept. The cited passage is shown from the ledger."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Open this file; `note` labels it (nil: the current file, verified to be the cited version).
        case open(URL, note: String?)
        case unavailable(Unavailable)
    }

    public static let newerVersionNote = "A newer version exists. This is the cited version (the copy kept when it was read)."
    public static let unpinnedNote = "This citation does not record which version it cites; the document's current file is shown."
    public static let unverifiableNote = "This version was recorded before content hashes; it could not be confirmed that the file is unchanged since it was cited."

    /// Resolve what to open for a citation of `sourceVersionID` (falling back to `objectID`'s file only
    /// when the citation pins no version, and saying so).
    public static func resolve(sourceVersionID: UUID?, objectID: UUID?, database: Database, ledgerURL: URL) async throws -> Outcome {
        guard let version = sourceVersionID else {
            guard let object = objectID, let url = try await fileURL(objectID: object, database: database) else { return .unavailable(.missingOriginal) }
            return FileManager.default.fileExists(atPath: url.path) ? .open(url, note: unpinnedNote) : .unavailable(.missingOriginal)
        }
        guard let row = try await database.query("""
            SELECT lower(content_hash), is_current, original_url, vault_address FROM source_versions WHERE id = ?;
            """, [.uuid(version)]).first, let hash = row.string(0) else {
            return .unavailable(.erased)
        }
        let isCurrent = (row.int(1) ?? 1) == 1
        // 1. The kept copy of exactly these bytes.
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        for address in [row.string(3), hash].compactMap({ $0 }) where !address.isEmpty {
            if let copy = await vault.url(for: address.lowercased()) { return .open(copy, note: isCurrent ? nil : newerVersionNote) }
        }
        // 2. Superseded and not kept: never the newer document in its place.
        guard isCurrent else { return .unavailable(.superseded) }
        // 3. The current version: the file on disk, only if its bytes are the cited ones.
        var candidate = row.string(2).flatMap(parseURL)
        if candidate == nil, let object = objectID { candidate = try await fileURL(objectID: object, database: database) }
        guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { return .unavailable(.missingOriginal) }
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return .open(url, note: unverifiableNote) }
        let onDisk = try await Task.detached(priority: .userInitiated) { try sha256(of: url) }.value
        return onDisk == hash ? .open(url, note: nil) : .unavailable(.changedOnDisk)
    }

    static func fileURL(objectID: UUID, database: Database) async throws -> URL? {
        try await database.query("SELECT f.url FROM knowledge_objects k JOIN files f ON f.id = k.file_id WHERE k.id = ? LIMIT 1;",
                                 [.uuid(objectID)]).first?.string(0).flatMap(parseURL)
    }

    static func parseURL(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u.isFileURL ? u : nil }
        return URL(fileURLWithPath: s)
    }

    /// SHA-256 of a file, streamed (lowercase hex).
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
