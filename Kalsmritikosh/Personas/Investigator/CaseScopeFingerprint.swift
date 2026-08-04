//
//  CaseScopeFingerprint.swift
//  Kalsmritikosh
//
//  INV-01-C4 — the ONE deterministic case-scope identity. Ask, Methods and DataLab all produce their
//  fingerprint through this single function, so a case-produced artifact can be checked for staleness the
//  same way regardless of which engine made it. The fingerprint is scope IDENTITY, not confidence: it is
//  a SHA-256 over a canonical, length-prefixed encoding of the case id, the case revision, and the sorted
//  resolved authorized source-version set (the exact scope the artifact was produced under). Sorting +
//  length prefixes make it order-independent and unambiguous; the same scope always yields the same 64-hex
//  string, a changed authorized set always yields a different one.
//

import Foundation
import CryptoKit

public nonisolated struct CaseScopeFingerprint: Sendable, Equatable, Hashable {
    /// 64-char lowercase-hex SHA-256 (matches the investigation_scope_artifacts CHECK).
    public let value: String
    public nonisolated init(value: String) { self.value = value }
}

public nonisolated enum CaseScopeFingerprinter {
    /// Bump only if the canonical encoding changes (it would change every fingerprint by design).
    private static let encodingVersion = "invscope-v1"

    /// The canonical fingerprint for a case's resolved scope. Deterministic and order-independent.
    public nonisolated static func fingerprint(caseID: UUID, caseRevision: Int, scope: RetrievalSourceScope) -> CaseScopeFingerprint {
        var canonical = field("v", encodingVersion)
        canonical += field("case", caseID.uuidString)
        canonical += field("rev", String(caseRevision))
        canonical += field("active", scope.isActive ? "1" : "0")
        let ids = scope.authorizedSourceVersionIDs.map(\.uuidString).sorted()
        canonical += field("count", String(ids.count))
        for id in ids { canonical += field("sv", id) }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return CaseScopeFingerprint(value: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Length-prefixed field so no two distinct inputs can collide by concatenation.
    private nonisolated static func field(_ key: String, _ value: String) -> String {
        "\(key):\(value.utf8.count):\(value)\n"
    }
}
