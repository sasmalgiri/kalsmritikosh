//
//  GraphStore.swift
//  Kalsmritikosh
//
//  Read-side over the relationships table. Used by the GraphRetriever
//  to walk entity-to-entity edges (works-with / sent / received /
//  mentioned / paid / contracted).
//

import Foundation

public actor GraphStore {
    private let relationships: RelationshipsRepository

    public init(relationships: RelationshipsRepository) {
        self.relationships = relationships
    }

    public func neighbors(of entityID: Entity.ID, limit: Int = 50) async throws -> [Relationship] {
        try await relationships.neighbors(of: entityID, limit: limit)
    }

    /// Walks two hops out and returns every edge encountered. Cheap
    /// enough for an alpha; for v1 we cap the breadth.
    public func twoHop(from entityID: Entity.ID, breadth: Int = 25) async throws -> [Relationship] {
        let first = try await relationships.neighbors(of: entityID, limit: breadth)
        var combined = first
        var seen: Set<Entity.ID> = [entityID]
        var order: [Entity.ID] = []
        for r in first {
            let next = r.fromEntityID == entityID ? r.toEntityID : r.fromEntityID
            if seen.insert(next).inserted { order.append(next) }
        }
        // Speed PERF-27 (owner 2026-11-23) — not tested yet: the second hop is one batched neighbour query,
        // appended in the same first-hop order.
        let second = try await relationships.neighbors(ofEach: order, limitEach: breadth)
        for next in order { combined.append(contentsOf: second[next] ?? []) }
        return combined
    }
}
