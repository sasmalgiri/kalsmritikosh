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

    /// Batch variant of `upsertEdge` — N edge upserts in ONE isolated savepoint, so disk writes
    /// amortize fsync cost. Each
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
        // F28 — the whole batch is ONE synchronous isolated unit. The old await-spanning
        // BEGIN/COMMIT let any other caller's write run inside it and vanish on rollback.
        try await database.withSavepoint("rel_upsert_edges") { db in
            for edge in edges {
                try Self.upsertEdge(db, kind: edge.kind, from: edge.from, to: edge.to,
                                    sourceObjectID: sourceObjectID, viaEventID: edge.viaEventID,
                                    confidence: confidence)
            }
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
        // Read-modify-write in one isolated unit: two concurrent callers can no longer both
        // read "absent" and both insert.
        try await database.withSavepoint("rel_upsert_edge") { db in
            try Self.upsertEdge(db, kind: kind, from: from, to: to, sourceObjectID: sourceObjectID,
                                viaEventID: viaEventID, confidence: confidence)
        }
    }

    /// The synchronous core, composable into the caller's savepoint.
    static func upsertEdge(_ db: isolated Database, kind: Relationship.Kind, from: Entity.ID, to: Entity.ID,
                           sourceObjectID: KnowledgeObject.ID, viaEventID: Event.ID?, confidence: Confidence) throws {
        let existing = try db.query("""
        SELECT id, weight, evidence_object_ids_json
        FROM relationships
        WHERE kind = ? AND from_entity_id = ? AND to_entity_id = ?
        LIMIT 1;
        """, [.text(kind.rawValue), .uuid(from), .uuid(to)])

        if let row = existing.first, let id = row.uuid(0) {
            let weight = Int(row.int(1) ?? 1)
            let evidence = EvidenceList.appending(sourceObjectID.uuidString, to: row.string(2) ?? "[]", cap: Self.evidenceCap)
            try db.exec("""
            UPDATE relationships
            SET weight = ?, evidence_object_ids_json = ?
            WHERE id = ?;
            """, [.integer(Int64(weight + 1)), .text(evidence), .uuid(id)])
        } else {
            try db.exec("""
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

    /// F09 — stable pages of an entity's relationships (ORDER BY id) so a caller can traverse all of
    /// them instead of an unordered first `limit`.
    public func neighbors(of entityID: Entity.ID, offset: Int, pageSize: Int) async throws -> [Relationship] {
        try await neighborsQuery(entityID, suffix: "ORDER BY id ASC LIMIT ? OFFSET ?",
                                 [.integer(Int64(pageSize)), .integer(Int64(offset))])
    }

    public func neighborCount(of entityID: Entity.ID) async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM relationships WHERE from_entity_id = ? OR to_entity_id = ?;",
                                     [.uuid(entityID), .uuid(entityID)]).first?.int(0) ?? 0)
    }

    /// F08 — relationships touching any of `entityIDs` whose source object belongs to one of
    /// `sourceVersionIDs` (current-version mapping), the scope predicate inside the query before LIMIT.
    public func touching(_ entityIDs: Set<Entity.ID>, sourceVersionIDs: Set<UUID>, limit: Int = 100) async throws -> [Relationship] {
        guard !entityIDs.isEmpty, !sourceVersionIDs.isEmpty else { return [] }
        let es = entityIDs.sorted { $0.uuidString < $1.uuidString }
        let vs = sourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        let ep = es.map { _ in "?" }.joined(separator: ","), vp = vs.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT r.id, r.kind, r.from_entity_id, r.to_entity_id, r.via_event_id, r.source_object_id, r.confidence
        FROM relationships r
        JOIN knowledge_objects ko ON ko.id = r.source_object_id
        JOIN source_versions sv ON sv.logical_source_id = ko.file_id AND sv.is_current = 1
        WHERE sv.id IN (\(vp)) AND (r.from_entity_id IN (\(ep)) OR r.to_entity_id IN (\(ep)))
        LIMIT ?;
        """, vs.map { .uuid($0) } + es.map { .uuid($0) } + es.map { .uuid($0) } + [.integer(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let kindRaw = row.string(1), let kind = Relationship.Kind(rawValue: kindRaw),
                  let from = row.uuid(2), let to = row.uuid(3), let src = row.uuid(5), let conf = row.double(6) else { return nil }
            return Relationship(id: id, kind: kind, fromEntityID: from, toEntityID: to, viaEventID: row.uuid(4),
                                sourceObjectID: src, confidence: Confidence(conf))
        }
    }

    public func neighbors(of entityID: Entity.ID, limit: Int = 100) async throws -> [Relationship] {
        try await neighborsQuery(entityID, suffix: "LIMIT ?", [.integer(Int64(limit))])
    }

    private func neighborsQuery(_ entityID: Entity.ID, suffix: String, _ tail: [SQLValue]) async throws -> [Relationship] {
        let rows = try await database.query("""
        SELECT id, kind, from_entity_id, to_entity_id, via_event_id, source_object_id, confidence
        FROM relationships
        WHERE from_entity_id = ? OR to_entity_id = ?
        \(suffix);
        """, [.uuid(entityID), .uuid(entityID)] + tail)

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

/// The evidence-id list carried on graph edges and fact bonds (JSON array of object ids):
/// append once, keep the newest `cap`. Pure, so it runs inside a synchronous savepoint body.
nonisolated enum EvidenceList {
    static func appending(_ id: String, to json: String, cap: Int) -> String {
        var list = (json.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        if !list.contains(id) {
            list.append(id)
            if list.count > cap { list = Array(list.suffix(cap)) }
        }
        return (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
