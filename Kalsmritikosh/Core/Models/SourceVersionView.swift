//
//  SourceVersionView.swift
//  Kalsmritikosh
//
//  EV-006 — one active version model. Two version-history mechanisms coexist in storage:
//  the canonical `source_versions` (05_CANONICAL_EVIDENCE_LEDGER §1: SourceDocument →
//  SourceVersion is authoritative) and the legacy PI.1 `file_versions` /
//  `knowledge_objects_history` archive. Rather than a destructive data merge over a live
//  archive (owner-gated), this consolidates the MODEL: one type + one ordering rule that
//  consumers read, with the canonical layer winning and legacy rows surfaced as
//  lower-confidence projections (§8) — never double-counted (§10 "no duplicate alias is
//  counted as independent evidence"), with exactly one current version (§2, §10).
//
//  Pure value types; the consolidator has no I/O so it is fully testable. Repositories map
//  their rows to the input records; nothing is moved or deleted.
//

import Foundation

/// A source version presented under the single unified model.
public struct SourceVersionView: Sendable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Hashable {
        case canonical   // from `source_versions` — authoritative
        case legacy      // from `file_versions` — compatibility projection, lower confidence
    }
    public let id: UUID
    public let logicalSourceID: UUID
    public let contentHash: String
    public let validFrom: Date
    public let isCurrent: Bool
    public let origin: Origin

    public nonisolated init(id: UUID, logicalSourceID: UUID, contentHash: String,
                            validFrom: Date, isCurrent: Bool, origin: Origin) {
        self.id = id
        self.logicalSourceID = logicalSourceID
        self.contentHash = contentHash
        self.validFrom = validFrom
        self.isCurrent = isCurrent
        self.origin = origin
    }
}

/// Minimal projection of a `source_versions` row.
public struct CanonicalVersionRecord: Sendable, Hashable {
    public let id: UUID
    public let logicalSourceID: UUID
    public let contentHash: String
    public let validFrom: Date
    public let isCurrent: Bool
    public nonisolated init(id: UUID, logicalSourceID: UUID, contentHash: String,
                            validFrom: Date, isCurrent: Bool) {
        self.id = id; self.logicalSourceID = logicalSourceID; self.contentHash = contentHash
        self.validFrom = validFrom; self.isCurrent = isCurrent
    }
}

/// Minimal projection of a legacy `file_versions` row (always a superseded archive entry).
public struct LegacyVersionRecord: Sendable, Hashable {
    public let versionID: UUID
    public let fileID: UUID
    public let contentHash: String?
    public let supersededAt: Date
    public nonisolated init(versionID: UUID, fileID: UUID, contentHash: String?, supersededAt: Date) {
        self.versionID = versionID; self.fileID = fileID
        self.contentHash = contentHash; self.supersededAt = supersededAt
    }
}

public enum VersionModelConsolidator {
    /// Unify the canonical and legacy version records for ONE logical source into a single
    /// ordered history (newest first). Rules (EV-006 / §2 / §8 / §10):
    ///   • canonical rows win — a legacy row whose content hash matches a canonical row is
    ///     dropped (not counted as independent evidence);
    ///   • legacy-only rows are surfaced but flagged `.legacy`;
    ///   • legacy rows are never `current` (they are the superseded archive);
    ///   • at most one `current` version survives — the canonical current; if two canonical
    ///     rows claim current (data drift), the newest `validFrom` wins and the rest are
    ///     demoted, so the model always exposes exactly one current.
    public nonisolated static func unify(
        canonical: [CanonicalVersionRecord],
        legacy: [LegacyVersionRecord]
    ) -> [SourceVersionView] {
        let canonicalHashes = Set(canonical.map(\.contentHash))

        // Resolve a single current among canonical rows (newest validFrom wins on conflict).
        let currentID: UUID? = canonical
            .filter(\.isCurrent)
            .max(by: { $0.validFrom < $1.validFrom })?.id

        var views: [SourceVersionView] = canonical.map { r in
            SourceVersionView(id: r.id, logicalSourceID: r.logicalSourceID,
                              contentHash: r.contentHash, validFrom: r.validFrom,
                              isCurrent: r.id == currentID, origin: .canonical)
        }
        for l in legacy {
            guard let hash = l.contentHash, !hash.isEmpty else { continue }
            if canonicalHashes.contains(hash) { continue }   // duplicate of a canonical version
            views.append(SourceVersionView(
                id: l.versionID, logicalSourceID: l.fileID, contentHash: hash,
                validFrom: l.supersededAt, isCurrent: false, origin: .legacy))
        }
        // Newest first; stable on ties by id for determinism.
        return views.sorted {
            $0.validFrom != $1.validFrom ? $0.validFrom > $1.validFrom
                                         : $0.id.uuidString < $1.id.uuidString
        }
    }
}
