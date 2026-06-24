//
//  BondWalker.swift
//  Kalsmritikosh
//
//  G3.16 — typed graph walker. Given a starting fact id (entity or
//  event) and a hop budget, walks the `fact_bonds` table to surface
//  related facts and the source KO ids that evidence the bonds. The
//  result is a small `WalkResult` value that the retriever and the
//  "Why this answer?" UI both consume.
//
//  Two flavors:
//    1. `expandFromEntity(_:bondNames:maxHops:)` — generic BFS over
//       outgoing AND incoming bonds. Bonded fact ids and the source
//       KO ids accumulate; cycles broken by a visited-set.
//    2. `walk(bonds:fromEntityID:)` — explicit path walk for the
//       Phase 5 explainer (e.g. "Person → affiliated_with →
//       Organization → delivered_for ← Project"). Phase 4 doesn't
//       need this path-explicit form yet, but it lays the contract.
//
//  Pure data movement; no scoring, no ranking. Caller decides how to
//  weight the chunks pulled from `sourceObjectIDs` against other
//  retrieval layers.
//

import Foundation

public actor BondWalker {
    public struct WalkResult: Sendable {
        /// Fact ids reached during the walk (excluding the seed).
        public let reachedFactIDs: Set<UUID>
        /// Source KO ids that evidence the bonds traversed. Ordered:
        /// first to appear during BFS comes first, so the caller's
        /// top-N truncation favours the closer hops.
        public let sourceObjectIDs: [UUID]
        /// One step per bond traversed. Useful for the Phase 5
        /// explainer; safe to ignore when only the KO ids matter.
        public let steps: [Step]

        public struct Step: Sendable, Hashable {
            public let bondName: String
            public let fromID: UUID
            public let toID: UUID
            public let sourceObjectID: UUID
        }

        public nonisolated init(
            reachedFactIDs: Set<UUID>,
            sourceObjectIDs: [UUID],
            steps: [Step]
        ) {
            self.reachedFactIDs = reachedFactIDs
            self.sourceObjectIDs = sourceObjectIDs
            self.steps = steps
        }
    }

    private let repository: FactBondsRepository
    /// Optional in-memory adjacency cache. When wired, all hop fetches
    /// hit the hashmap instead of SQL — multi-hop walks drop from
    /// ~50-200 SQL queries to O(reached) dictionary lookups. SQLite
    /// stays the source of truth; the cache is rebuilt on cold start.
    private let cache: InMemoryBondGraph?
    /// Hard ceiling — prevents a runaway walk on a dense graph from
    /// hammering SQLite with thousands of queries.
    private let perHopLimit: Int

    public init(
        repository: FactBondsRepository,
        cache: InMemoryBondGraph? = nil,
        perHopLimit: Int = 50
    ) {
        self.repository = repository
        self.cache = cache
        self.perHopLimit = perHopLimit
    }

    /// BFS over both directions of fact_bonds.
    ///
    /// - Parameters:
    ///   - seed: starting fact id (entity OR event UUID).
    ///   - bondNames: when non-empty, only bonds with these names are
    ///     traversed. Empty = walk every bond. Restricting names is
    ///     how the caller asks a typed multihop ("walk only sent_by
    ///     and received_by").
    ///   - maxHops: upper bound on edge depth. 1 = direct neighbors,
    ///     2 = friend-of-friend, etc. Capped at 3 in practice.
    public func expand(
        from seed: UUID,
        bondNames: Set<String> = [],
        maxHops: Int = 2
    ) async -> WalkResult {
        let hops = max(0, min(maxHops, 3))
        var visited: Set<UUID> = [seed]
        var sourceIDs: [UUID] = []
        var sourceSet: Set<UUID> = []
        var steps: [WalkResult.Step] = []
        var frontier: [UUID] = [seed]

        for _ in 0..<hops {
            var nextFrontier: [UUID] = []
            for current in frontier {
                // Outgoing
                let out: [FactBondsRepository.Bond]
                do {
                    out = try await fetchOutgoing(from: current, bondNames: bondNames)
                } catch {
                    out = []
                }
                for bond in out {
                    record(
                        bond: bond,
                        from: bond.fromID,
                        to: bond.toID,
                        visited: &visited,
                        sourceIDs: &sourceIDs,
                        sourceSet: &sourceSet,
                        steps: &steps,
                        nextFrontier: &nextFrontier
                    )
                }
                // Incoming — walking incoming makes "what emails did
                // Alice receive?" answerable from Alice's id.
                let inc: [FactBondsRepository.Bond]
                do {
                    inc = try await fetchIncoming(to: current, bondNames: bondNames)
                } catch {
                    inc = []
                }
                for bond in inc {
                    record(
                        bond: bond,
                        from: bond.fromID,
                        to: bond.toID,
                        visited: &visited,
                        sourceIDs: &sourceIDs,
                        sourceSet: &sourceSet,
                        steps: &steps,
                        nextFrontier: &nextFrontier
                    )
                }
            }
            if nextFrontier.isEmpty { break }
            frontier = nextFrontier
        }

        var reached = visited
        reached.remove(seed)
        return WalkResult(
            reachedFactIDs: reached,
            sourceObjectIDs: sourceIDs,
            steps: steps
        )
    }

    // MARK: - Internals

    private func fetchOutgoing(
        from id: UUID,
        bondNames: Set<String>
    ) async throws -> [FactBondsRepository.Bond] {
        // Hot path: cache lookup is O(1) + in-memory filter. Only
        // when warm — during the boot warm-up window the SQL fallback
        // runs so we don't silently return empty walks.
        if let cache, await cache.isWarm() {
            let hits = await cache.outgoing(from: id, bondNames: bondNames)
            return Array(hits.prefix(perHopLimit))
        }
        // Fallback: SQL per hop.
        if bondNames.isEmpty {
            return try await repository.outgoing(from: id, limit: perHopLimit)
        }
        var merged: [FactBondsRepository.Bond] = []
        for name in bondNames {
            merged.append(contentsOf: try await repository.outgoing(
                from: id, named: name, limit: perHopLimit
            ))
        }
        return merged
    }

    private func fetchIncoming(
        to id: UUID,
        bondNames: Set<String>
    ) async throws -> [FactBondsRepository.Bond] {
        if let cache, await cache.isWarm() {
            let hits = await cache.incoming(to: id, bondNames: bondNames)
            return Array(hits.prefix(perHopLimit))
        }
        if bondNames.isEmpty {
            return try await repository.incoming(to: id, limit: perHopLimit)
        }
        var merged: [FactBondsRepository.Bond] = []
        for name in bondNames {
            merged.append(contentsOf: try await repository.incoming(
                to: id, named: name, limit: perHopLimit
            ))
        }
        return merged
    }

    private func record(
        bond: FactBondsRepository.Bond,
        from: UUID,
        to: UUID,
        visited: inout Set<UUID>,
        sourceIDs: inout [UUID],
        sourceSet: inout Set<UUID>,
        steps: inout [WalkResult.Step],
        nextFrontier: inout [UUID]
    ) {
        let other = visited.contains(from) ? to : from
        if visited.insert(other).inserted {
            nextFrontier.append(other)
        }
        if sourceSet.insert(bond.sourceObjectID).inserted {
            sourceIDs.append(bond.sourceObjectID)
        }
        steps.append(.init(
            bondName: bond.bondName,
            fromID: from,
            toID: to,
            sourceObjectID: bond.sourceObjectID
        ))
    }
}
