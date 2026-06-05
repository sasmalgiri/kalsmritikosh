//
//  EntitiesRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor EntitiesRepository {
    private let database: Database
    private let encoder = JSONEncoder()

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ entities: [Entity]) async throws {
        for e in entities {
            let attrs = try encoder.encode(e.attributes)
            try await database.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(e.id),
                .text(e.kind.rawValue),
                .text(e.value),
                .optionalText(e.normalizedValue),
                .uuid(e.sourceObjectID),
                .real(e.confidence.value),
                .text(String(data: attrs, encoding: .utf8) ?? "{}")
            ])
        }
    }

    public func count(of kind: Entity.Kind) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM entities WHERE kind = ?;",
            [.text(kind.rawValue)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    public func list(kind: Entity.Kind, limit: Int = 200) async throws -> [EntitySummaryRow] {
        let rows = try await database.query("""
        SELECT id, value, normalized, confidence
        FROM entities WHERE kind = ?
        ORDER BY value COLLATE NOCASE
        LIMIT ?;
        """, [.text(kind.rawValue), .integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let value = row.string(1),
                let conf = row.double(3)
            else { return nil }
            return EntitySummaryRow(
                id: id,
                value: value,
                normalizedValue: row.string(2),
                confidence: Confidence(conf)
            )
        }
    }

    public func find(byID id: Entity.ID) async throws -> Entity? {
        let rows = try await database.query("""
        SELECT id, kind, value, normalized, source_object_id, confidence
        FROM entities WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        return rows.first.flatMap(decodeFullEntity)
    }

    public func find(byValue value: String, limit: Int = 25) async throws -> [Entity] {
        let pattern = "%\(value)%"
        let rows = try await database.query("""
        SELECT id, kind, value, normalized, source_object_id, confidence
        FROM entities
        WHERE value LIKE ? OR normalized LIKE ?
        ORDER BY confidence DESC
        LIMIT ?;
        """, [.text(pattern), .text(pattern), .integer(Int64(limit))])
        return rows.compactMap(decodeFullEntity)
    }

    private func decodeFullEntity(_ row: SQLRow) -> Entity? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = Entity.Kind(rawValue: kindRaw),
            let value = row.string(2),
            let sourceID = row.uuid(4),
            let conf = row.double(5)
        else { return nil }
        return Entity(
            id: id,
            kind: kind,
            value: value,
            normalizedValue: row.string(3),
            sourceObjectID: sourceID,
            confidence: Confidence(conf)
        )
    }

    public func search(value query: String, limit: Int = 50) async throws -> [EntitySummaryRow] {
        let pattern = "%\(query)%"
        let rows = try await database.query("""
        SELECT id, value, normalized, confidence
        FROM entities
        WHERE value LIKE ? OR normalized LIKE ?
        ORDER BY confidence DESC
        LIMIT ?;
        """, [.text(pattern), .text(pattern), .integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let value = row.string(1),
                let conf = row.double(3)
            else { return nil }
            return EntitySummaryRow(
                id: id,
                value: value,
                normalizedValue: row.string(2),
                confidence: Confidence(conf)
            )
        }
    }
}

public struct EntitySummaryRow: Identifiable, Sendable, Hashable {
    public let id: Entity.ID
    public let value: String
    public let normalizedValue: String?
    public let confidence: Confidence
}
