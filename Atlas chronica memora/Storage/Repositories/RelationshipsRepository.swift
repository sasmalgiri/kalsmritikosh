//
//  RelationshipsRepository.swift
//  Atlas chronica memora
//

import Foundation

public actor RelationshipsRepository {
    private let database: Database
    private let encoder = JSONEncoder()

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ relationships: [Relationship]) async throws {
        for r in relationships {
            let attrs = try encoder.encode(r.attributes)
            try await database.exec("""
            INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                       source_object_id, confidence, attributes_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(r.id),
                .text(r.kind.rawValue),
                .uuid(r.fromEntityID),
                .uuid(r.toEntityID),
                r.viaEventID.map { .uuid($0) } ?? .null,
                .uuid(r.sourceObjectID),
                .real(r.confidence.value),
                .text(String(data: attrs, encoding: .utf8) ?? "{}")
            ])
        }
    }

    public func neighbors(of entityID: Entity.ID, limit: Int = 100) async throws -> [Relationship] {
        let rows = try await database.query("""
        SELECT id, kind, from_entity_id, to_entity_id, via_event_id, source_object_id, confidence
        FROM relationships
        WHERE from_entity_id = ? OR to_entity_id = ?
        LIMIT ?;
        """, [.uuid(entityID), .uuid(entityID), .integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let kindRaw = row.string(1),
                let kind = Relationship.Kind(rawValue: kindRaw),
                let from = row.uuid(2),
                let to = row.uuid(3),
                let src = row.uuid(5),
                let conf = row.double(6)
            else { return nil }
            return Relationship(
                id: id,
                kind: kind,
                fromEntityID: from,
                toEntityID: to,
                viaEventID: row.uuid(4),
                sourceObjectID: src,
                confidence: Confidence(conf)
            )
        }
    }
}
