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

    /// Batch variant of `upsertEdge` — wraps N edge upserts in a single
    /// BEGIN IMMEDIATE / COMMIT so disk writes amortize fsync cost. Each
    /// edge tuple is canonical-ordered by the caller per the rules in
    /// `upsertEdge`. ROLLBACK on partial failure so the table either gets
    /// the full batch or none of it.
    public struct EdgeUpsert: Sendable {
        public let kind: Relationship.Kind
        public let from: Entity.ID
        public let to: Entity.ID
        public let viaEventID: Event.ID?

        public init(
            kind: Relationship.Kind,
            from: Entity.ID,
            to: Entity.ID,
            viaEventID: Event.ID? = nil
        ) {
            self.kind = kind
            self.from = from
            self.to = to
            self.viaEventID = viaEventID
        }
    }

    public func upsertEdges(
        _ edges: [EdgeUpsert],
        sourceObjectID: KnowledgeObject.ID,
        confidence: Confidence = .medium
    ) async throws {
        guard !edges.isEmpty else { return }
        // Same gate as FactBondsRepository — concurrent IngestCoordinator
        // fan-out caused nested BEGINs to fail.
        try await database.beginTransaction()
        do {
            for edge in edges {
                try await upsertEdge(
                    kind: edge.kind,
                    from: edge.from,
                    to: edge.to,
                    sourceObjectID: sourceObjectID,
                    viaEventID: edge.viaEventID,
                    confidence: confidence
                )
            }
            try await database.commitTransaction()
        } catch {
            await database.rollbackTransaction()
            throw error
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

    /// Weighted money-flow edges with both endpoints' canonical labels, for
    /// the fund-flow visualization. Defaults to `paid` edges (payer → payee).
    /// Edge `weight` is the corroboration count (how many times the payment
    /// relationship was observed); `evidenceCount` is the number of distinct
    /// source documents backing it. Ordered by weight so the strongest flows
    /// come first when the caller caps the set.
    public func fundFlowEdges(
        kinds: [Relationship.Kind] = [.paid],
        limit: Int = 400
    ) async throws -> [FundFlowEdge] {
        guard !kinds.isEmpty else { return [] }
        // Enum rawValues are a fixed, safe vocabulary — no injection surface.
        let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT r.from_entity_id, r.to_entity_id, r.weight, r.evidence_object_ids_json,
               ef.value AS from_label, et.value AS to_label
        FROM relationships r
        JOIN entities ef ON ef.id = r.from_entity_id
        JOIN entities et ON et.id = r.to_entity_id
        WHERE r.kind IN (\(kindList))
          AND ef.review_status IS NULL AND ef.merged_into IS NULL
          AND et.review_status IS NULL AND et.merged_into IS NULL
        ORDER BY r.weight DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { row in
            guard
                let from = row.uuid(0),
                let to = row.uuid(1),
                let fromLabel = row.string(4),
                let toLabel = row.string(5)
            else { return nil }
            let weight = Int(row.int(2) ?? 1)
            let evidence = parseEvidence(row.string(3) ?? "[]").count
            return FundFlowEdge(
                fromID: from, toID: to,
                fromLabel: fromLabel, toLabel: toLabel,
                weight: max(1, weight), evidenceCount: evidence)
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

/// A payer → payee money-flow edge with resolved labels, for the fund-flow view.
public struct FundFlowEdge: Sendable, Hashable, Identifiable {
    public var id: String { "\(fromID.uuidString)->\(toID.uuidString)" }
    public let fromID: Entity.ID
    public let toID: Entity.ID
    public let fromLabel: String
    public let toLabel: String
    public let weight: Int
    public let evidenceCount: Int
}
