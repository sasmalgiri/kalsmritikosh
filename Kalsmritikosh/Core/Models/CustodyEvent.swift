//
//  CustodyEvent.swift
//  Kalsmritikosh
//
//  T18 — one append-only chain-of-custody record for a source file (§21).
//  Every acquisition, hash computation/verification, export, and disclosure
//  is a new row. A hash MISMATCH on re-ingest is recorded, never silently
//  overwritten — tampering is surfaced, not hidden.
//

import Foundation

public nonisolated struct CustodyEvent: Identifiable, Sendable, Hashable, Codable {
    public typealias ID = UUID

    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        /// File first acquired into the archive.
        case acquired
        /// SHA-256 computed at ingest.
        case hashComputed = "hash_computed"
        /// Re-ingest confirmed the stored hash still matches.
        case hashVerified = "hash_verified"
        /// Re-ingest found the content hash changed — possible tampering.
        case hashMismatch = "hash_mismatch"
        /// Content exported out of the system.
        case exported
        /// Disclosed to a named party.
        case disclosed

        public var displayName: String {
            switch self {
            case .acquired:     return "Acquired"
            case .hashComputed: return "Hash computed"
            case .hashVerified: return "Hash verified"
            case .hashMismatch: return "Hash mismatch"
            case .exported:     return "Exported"
            case .disclosed:    return "Disclosed"
            }
        }
    }

    public let id: ID
    public let fileID: UUID
    public let kind: Kind
    public let actor: String
    public let at: Date
    /// Free-text detail (e.g. the party disclosed to, the destination path).
    public let detail: String?
    /// The SHA-256 involved, when relevant.
    public let hash: String?

    public nonisolated init(
        id: ID = UUID(),
        fileID: UUID,
        kind: Kind,
        actor: String = "system",
        at: Date = Date(),
        detail: String? = nil,
        hash: String? = nil
    ) {
        self.id = id
        self.fileID = fileID
        self.kind = kind
        self.actor = actor
        self.at = at
        self.detail = detail
        self.hash = hash
    }
}
