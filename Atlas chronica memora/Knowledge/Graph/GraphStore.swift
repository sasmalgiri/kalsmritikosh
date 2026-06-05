//
//  GraphStore.swift
//  Atlas chronica memora
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
        for r in first {
            let next = r.fromEntityID == entityID ? r.toEntityID : r.fromEntityID
            if seen.insert(next).inserted {
                let more = try await relationships.neighbors(of: next, limit: breadth)
                combined.append(contentsOf: more)
            }
        }
        return combined
    }
}
