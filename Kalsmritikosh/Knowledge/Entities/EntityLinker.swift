//
//  EntityLinker.swift
//  Kalsmritikosh
//
//  Folds redundant entity rows together when their normalized values
//  match. Emails and phone numbers normalize aggressively; people and
//  organizations use case-insensitive equality (Jaro-Winkler-style
//  fuzzy match arrives in M5 once we add a string-distance dep).
//

import Foundation

public struct EntityLinker: Sendable {
    public nonisolated init() {}

    public nonisolated func link(_ entities: [Entity]) -> [Entity] {
        // Group by (kind, normalized), keep the highest-confidence
        // representative. Source IDs of merged duplicates AND their
        // attributes get folded into the representative — no data lost.
        //
        // Real-data audit (2026-06-28) caught the silent-T1-drop bug
        // here: the previous version's `Entity(id:, kind:, value:, …)`
        // initializer call omitted `qualityTier:`, so the default
        // `.t2` clobbered any structured-header T1 tag the upstream
        // annotate() had set. Result: 0 T1 entities in the entire
        // database even though the EmailLoader was writing them
        // correctly. Fix: explicitly carry qualityTier through
        // AND promote on merge (MIN by raw string is correct because
        // "T1" < "T2" < "T3" alphabetically).
        var representatives: [Key: Entity] = [:]
        var mergedSources: [Key: [KnowledgeObject.ID]] = [:]
        var mergedAttributes: [Key: [String: AnyCodable]] = [:]
        var bestTier: [Key: QualityTier] = [:]

        for entity in entities {
            let key = Key(kind: entity.kind, normalized: normalize(entity))
            // Always accumulate attributes from every duplicate. The
            // representative wins on conflict; duplicates only fill gaps.
            var attrs = mergedAttributes[key] ?? [:]
            for (k, v) in entity.attributes where attrs[k] == nil {
                attrs[k] = v
            }
            mergedAttributes[key] = attrs

            // Promote-only tier merge: if either the existing or the
            // new entity carries a better (alphabetically smaller)
            // tier, the merged row inherits it.
            let priorTier = bestTier[key]
            if let priorTier {
                bestTier[key] = (entity.qualityTier.rawValue < priorTier.rawValue) ? entity.qualityTier : priorTier
            } else {
                bestTier[key] = entity.qualityTier
            }

            if let existing = representatives[key] {
                if entity.confidence > existing.confidence {
                    // New winner — its own attributes take priority over
                    // earlier-merged ones on key conflict.
                    var merged = mergedAttributes[key] ?? [:]
                    for (k, v) in entity.attributes { merged[k] = v }
                    mergedAttributes[key] = merged
                    representatives[key] = entity
                }
                mergedSources[key, default: []].append(entity.sourceObjectID)
            } else {
                representatives[key] = entity
                mergedSources[key, default: []] = []
            }
        }

        return representatives.map { key, entity in
            var attrs = mergedAttributes[key] ?? entity.attributes
            let sources = mergedSources[key] ?? []
            if !sources.isEmpty {
                attrs["mergedSourceCount"] = AnyCodable(.int(Int64(sources.count)))
            }
            return Entity(
                id: entity.id,
                kind: entity.kind,
                value: entity.value,
                normalizedValue: key.normalized,
                sourceObjectID: entity.sourceObjectID,
                sourceRange: entity.sourceRange,
                confidence: entity.confidence,
                attributes: attrs,
                qualityTier: bestTier[key] ?? entity.qualityTier
            )
        }
    }

    private nonisolated func normalize(_ entity: Entity) -> String {
        switch entity.kind {
        case .emailAddress:
            return entity.value.lowercased()
        case .phoneNumber:
            return entity.value.filter(\.isNumber)
        case .person, .organization, .vendor, .client:
            return entity.value
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return entity.normalizedValue ?? entity.value.lowercased()
        }
    }

    private nonisolated struct Key: Hashable {
        let kind: Entity.Kind
        let normalized: String
    }
}
