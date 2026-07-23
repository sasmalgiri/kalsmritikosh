//
//  SourceIndependenceGroup.swift
//  Kalsmritikosh
//
//  HIST-035 (Universal History program, Phase 6). Duplicates must NOT count as
//  independent corroboration. Sources are grouped by an independence key (content
//  hash, email message id, attachment-parent, forwarded/exported/quoted copy,
//  same DB record version, same lineage). Corroboration strength = number of
//  DISTINCT groups, never the raw source count. Deterministic.
//

import Foundation

/// Resolves reliable, persisted independence keys (content hash / message id / lineage) for
/// a set of objects, in ONE batch. Missing or uncertain identity data must be omitted (left
/// nil) — object id, filename, retrieval rank and order are NEVER independence keys. When no
/// provider is wired the caller stays conservative (no key ⇒ no corroboration). (C2.1)
public protocol SourceIndependenceKeyProvider: Sendable {
    func keys(for objectIDs: Set<KnowledgeObject.ID>) async throws -> [KnowledgeObject.ID: String]
}

public struct SourceIndependenceGrouper: Sendable {
    public init() {}

    /// Group object ids by their independence key. Objects with the SAME key are
    /// one group (copies of one source); objects with no key are their own group
    /// (treated as independent). Groups + members are returned in stable order.
    public func groups(objectIDs: [KnowledgeObject.ID],
                       keys: [KnowledgeObject.ID: String]) -> [[KnowledgeObject.ID]] {
        var byKey: [String: [KnowledgeObject.ID]] = [:]
        var singletons: [[KnowledgeObject.ID]] = []
        var seen = Set<KnowledgeObject.ID>()
        for oid in objectIDs where seen.insert(oid).inserted {
            if let key = keys[oid], !key.isEmpty {
                byKey[key, default: []].append(oid)
            } else {
                singletons.append([oid])
            }
        }
        let keyed = byKey.keys.sorted().map { key in
            byKey[key]!.sorted { $0.uuidString < $1.uuidString }
        }
        // Stable overall order: keyed groups (by key) then singletons (by id).
        return keyed + singletons.sorted { ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "") }
    }

    /// Independent corroboration count = number of distinct source groups.
    public func independentCount(objectIDs: [KnowledgeObject.ID],
                                 keys: [KnowledgeObject.ID: String]) -> Int {
        groups(objectIDs: objectIDs, keys: keys).count
    }

    /// True when the evidence, after collapsing copies, comes from more than one
    /// independent source — the honest test for "corroborated".
    public func isCorroborated(objectIDs: [KnowledgeObject.ID],
                               keys: [KnowledgeObject.ID: String]) -> Bool {
        independentCount(objectIDs: objectIDs, keys: keys) >= 2
    }

    // MARK: - Conservative count for ASSERTABILITY (C2 mandatory safeguard)

    /// A CONSERVATIVE independent-source count for corroboration decisions. Unlike
    /// `independentCount`, an object WITHOUT a reliable (non-empty) independence key does
    /// NOT count as its own independent source — because missing key coverage is not proof
    /// of independence, and two unkeyed forwarded/duplicate copies must never look like two
    /// independent sources. Only DISTINCT, non-empty, trimmed keys raise this count.
    ///
    /// Unkeyed evidence may still SUPPORT an attributed assertion (exactEvidenceCount can be
    /// ≥1); it just can't make a claim `corroborated`. The history reconciliation path keeps
    /// using `independentCount` unchanged; this API exists solely for AssertabilityPolicy.
    public func verifiedIndependentCount(objectIDs: [KnowledgeObject.ID],
                                         keys: [KnowledgeObject.ID: String]) -> Int {
        let reliableKeys = Set(
            objectIDs.compactMap { oid -> String? in
                guard let key = keys[oid] else { return nil }
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )
        return reliableKeys.count
    }
}
