//
//  WalkExplainer.swift
//  Kalsmritikosh
//
//  G3.20 — translate `BondWalker.WalkResult.Step` (raw bond steps
//  carrying just UUIDs) into the typed `WalkStep` model defined in
//  FactSchema.swift (carrying FactType endpoints + evidence ids).
//  The Phase 5 "Why this answer?" UI renders this list as the chain
//  of reasoning that produced the answer.
//
//  Strategy:
//  - For each unique fact UUID across the walk, look up its
//    persisted fact_type. Entities and events live in separate
//    tables, so try entity first (most bonds anchor on entity-side
//    facts) and fall back to event when nil. Cache lookups so a
//    20-step walk hits SQLite N + M times, not 2N.
//  - Adjacent steps that share a (fromFact, bond, toFact) tuple
//    collapse — their evidence ids merge. A walk that crosses the
//    same bond name twice for the same FactType pair is usually a
//    single semantic step backed by two source KOs.
//  - Steps whose endpoints don't classify are dropped. The walk
//    happened in the graph, but the UI can't explain a step it
//    can't name.
//

import Foundation

public actor WalkExplainer {
    private let entities: EntitiesRepository
    private let events: EventsRepository
    /// Optional in-memory fact_type index. When wired, every step's
    /// endpoint resolution is a O(1) dictionary lookup instead of two
    /// SQL queries (entity then event). For a 50-step walk that's
    /// 100 SQL round-trips collapsed to zero.
    private let cache: InMemoryBondGraph?

    public init(
        entities: EntitiesRepository,
        events: EventsRepository,
        cache: InMemoryBondGraph? = nil
    ) {
        self.entities = entities
        self.events = events
        self.cache = cache
    }

    /// Translate raw bond steps into typed walk steps. Order is
    /// preserved; adjacent identical (fromFact, bond, toFact) steps
    /// merge their evidence ids.
    public func explain(_ steps: [BondWalker.WalkResult.Step]) async -> [WalkStep] {
        guard !steps.isEmpty else { return [] }

        // Build a fact-type cache for every UUID we'll touch.
        var ids = Set<UUID>()
        for s in steps {
            ids.insert(s.fromID)
            ids.insert(s.toID)
        }
        var typeCache: [UUID: FactType] = [:]
        for id in ids {
            if let t = await resolveFactType(id) {
                typeCache[id] = t
            }
        }

        // Translate + drop steps whose endpoints aren't classified.
        var raw: [WalkStep] = []
        for s in steps {
            guard let from = typeCache[s.fromID],
                  let to = typeCache[s.toID] else { continue }
            raw.append(WalkStep(
                fromFact: from,
                bond: s.bondName,
                toFact: to,
                evidenceObjectIDs: [s.sourceObjectID]
            ))
        }

        // Merge adjacent identical (from, bond, to) triples.
        var merged: [WalkStep] = []
        for step in raw {
            if let last = merged.last,
               last.fromFact == step.fromFact,
               last.toFact == step.toFact,
               last.bond == step.bond {
                var evidence = last.evidenceObjectIDs
                for id in step.evidenceObjectIDs where !evidence.contains(id) {
                    evidence.append(id)
                }
                merged.removeLast()
                merged.append(WalkStep(
                    fromFact: last.fromFact,
                    bond: last.bond,
                    toFact: last.toFact,
                    evidenceObjectIDs: evidence
                ))
            } else {
                merged.append(step)
            }
        }
        return merged
    }

    // MARK: - Internals

    /// Resolve a UUID to its FactType by consulting the entity table
    /// first, then the event table. Returns nil when neither row is
    /// classified — the caller drops the step. Hot path is the cache
    /// when wired (O(1) hashmap); SQL is the fallback.
    private func resolveFactType(_ id: UUID) async -> FactType? {
        if let cache, await cache.isWarm(),
           let type = await cache.factType(for: id) {
            return type
        }
        // `try? await ...` returns `String??` (throws + nullable col),
        // so flatten both layers in one shot.
        if let typeRaw = (try? await entities.lookupFactType(forEntityID: id)) ?? nil,
           let type = FactType(rawValue: typeRaw) {
            return type
        }
        if let typeRaw = (try? await events.lookupFactType(forEventID: id)) ?? nil,
           let type = FactType(rawValue: typeRaw) {
            return type
        }
        return nil
    }
}
