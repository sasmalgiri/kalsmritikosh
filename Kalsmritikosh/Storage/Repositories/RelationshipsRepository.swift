//
//  RelationshipsRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor RelationshipsRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Max number of source KO ids retained per relationship.
    public static let evidenceCap = 20

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ relationships: [Relationship]) async throws {
        for r in relationships {
            let attrs = try encoder.encode(r.attributes)
            try await database.exec("""
            INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                       source_object_id, confidence, attributes_json,
                                       weight, evidence_object_ids_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?);
            """, [
                .uuid(r.id),
                .text(r.kind.rawValue),
                .uuid(r.fromEntityID),
                .uuid(r.toEntityID),
                r.viaEventID.map { .uuid($0) } ?? .null,
                .uuid(r.sourceObjectID),
                .real(r.confidence.value),
                .text(String(data: attrs, encoding: .utf8) ?? "{}"),
                .text("[\"\(r.sourceObjectID.uuidString)\"]")
            ])
        }
    }

    /// Upsert a graph edge: increments weight by 1 and appends the
    /// source KO id to the evidence list (capped at `evidenceCap`).
    /// Edge direction is preserved as given — callers MUST canonicalize
    /// undirected edges (co_occurs / event_linked) before calling.
    public func upsertEdge(
        kind: Relationship.Kind,
        from: Entity.ID,
        to: Entity.ID,
        sourceObjectID: KnowledgeObject.ID,
        viaEventID: Event.ID? = nil,
        confidence: Confidence = .medium
    ) async throws {
        let existing = try await database.query("""
        SELECT id, weight, evidence_object_ids_json
        FROM relationships
        WHERE kind = ? AND from_entity_id = ? AND to_entity_id = ?
        LIMIT 1;
        """, [.text(kind.rawValue), .uuid(from), .uuid(to)])

        if let row = existing.first,
           let id = row.uuid(0) {
            let weight = Int(row.int(1) ?? 1)
            var evidence = parseEvidence(row.string(2) ?? "[]")
            let srcStr = sourceObjectID.uuidString
            if !evidence.contains(srcStr) {
                evidence.append(srcStr)
                if evidence.count > Self.evidenceCap {
                    evidence = Array(evidence.suffix(Self.evidenceCap))
                }
            }
            try await database.exec("""
            UPDATE relationships
            SET weight = ?, evidence_object_ids_json = ?
            WHERE id = ?;
            """, [
                .integer(Int64(weight + 1)),
                .text(serializeEvidence(evidence)),
                .uuid(id)
            ])
        } else {
            try await database.exec("""
            INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                       source_object_id, confidence, attributes_json,
                                       weight, evidence_object_ids_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, '{}', 1, ?);
            """, [
                .uuid(UUID()),
                .text(kind.rawValue),
                .uuid(from),
                .uuid(to),
                viaEventID.map { .uuid($0) } ?? .null,
                .uuid(sourceObjectID),
                .real(confidence.value),
                .text("[\"\(sourceObjectID.uuidString)\"]")
            ])
        }
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM relationships;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    public func count(ofKind kind: Relationship.Kind) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM relationships WHERE kind = ?;",
            [.text(kind.rawValue)]
        )
        return Int(rows.first?.int(0) ?? 0)
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

    // MARK: - JSON evidence list helpers

    private func parseEvidence(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private func serializeEvidence(_ list: [String]) -> String {
        guard let data = try? encoder.encode(list),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
