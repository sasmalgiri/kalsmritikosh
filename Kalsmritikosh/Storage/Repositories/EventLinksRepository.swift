//
//  EventLinksRepository.swift
//  Kalsmritikosh
//
//  HISTORY Phase G.3 — typed causal links between events.
//
//  Append-only. Supersession via the `superseded_by` column rather
//  than UPDATE so the link history stays auditable. Counterfactuals
//  live in a SEPARATE table (`event_links_hypothetical`) — this
//  repository never UNIONs them with verified links.
//

import Foundation

public actor EventLinksRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Writes

    /// Insert a single link. Caller is responsible for de-dup checks
    /// upstream (the discoverer does so by hashing on source+target+
    /// relation before calling).
    public func insert(_ link: CausalLink) async throws {
        let evidenceData = try encoder.encode(link.evidenceObjectIDs)
        let evidenceJSON = String(data: evidenceData, encoding: .utf8) ?? "[]"
        try await database.exec("""
        INSERT INTO event_links
            (id, source_event_id, target_event_id, relation, confidence,
             evidence_object_ids_json, allen, source, reason, created_at, superseded_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(link.id),
            .uuid(link.sourceEventID),
            .uuid(link.targetEventID),
            .text(link.relation.rawValue),
            .real(link.confidence),
            .text(evidenceJSON),
            link.allen.map { .text($0.rawValue) } ?? .null,
            .text(link.source.rawValue),
            link.reason.map { .text($0) } ?? .null,
            .real(link.createdAt.timeIntervalSince1970),
            link.supersededBy.map { .uuid($0) } ?? .null
        ])
    }

    /// Replace `oldLinkID` with `newLink` in a single transaction:
    /// stamp `superseded_by = newLink.id` on the old row, then insert
    /// the new row. Both stay queryable; reads filter on
    /// `superseded_by IS NULL` to see only current.
    public func supersede(oldLinkID: UUID, with newLink: CausalLink) async throws {
        try await database.exec("SAVEPOINT atlas_link_supersede;")
        do {
            try await database.exec(
                "UPDATE event_links SET superseded_by = ? WHERE id = ?;",
                [.uuid(newLink.id), .uuid(oldLinkID)]
            )
            try await insert(newLink)
            try await database.exec("RELEASE SAVEPOINT atlas_link_supersede;")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT atlas_link_supersede;")
            try? await database.exec("RELEASE SAVEPOINT atlas_link_supersede;")
            throw error
        }
    }

    // MARK: - Reads

    public func count(includeSuperseded: Bool = false) async throws -> Int {
        let sql = includeSuperseded
            ? "SELECT COUNT(*) FROM event_links;"
            : "SELECT COUNT(*) FROM event_links WHERE superseded_by IS NULL;"
        let rows = try await database.query(sql, [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// All current (non-superseded) links where the given event is
    /// the SOURCE — "what did this event cause / contribute to?".
    public func outgoing(from eventID: Event.ID) async throws -> [CausalLink] {
        let rows = try await database.query("""
        SELECT id, source_event_id, target_event_id, relation, confidence,
               evidence_object_ids_json, allen, source, reason, created_at, superseded_by
        FROM event_links
        WHERE source_event_id = ? AND superseded_by IS NULL
        ORDER BY confidence DESC;
        """, [.uuid(eventID)])
        return rows.compactMap(decodeRow)
    }

    /// All current links where the given event is the TARGET — "what
    /// caused / contributed to this event?".
    public func incoming(to eventID: Event.ID) async throws -> [CausalLink] {
        let rows = try await database.query("""
        SELECT id, source_event_id, target_event_id, relation, confidence,
               evidence_object_ids_json, allen, source, reason, created_at, superseded_by
        FROM event_links
        WHERE target_event_id = ? AND superseded_by IS NULL
        ORDER BY confidence DESC;
        """, [.uuid(eventID)])
        return rows.compactMap(decodeRow)
    }

    /// Pull links by relation in the time window [start, end). Used
    /// by the narrative composer's chapter-render pass to surface
    /// causal chains inline.
    public func links(in eventIDs: [Event.ID]) async throws -> [CausalLink] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = eventIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT id, source_event_id, target_event_id, relation, confidence,
               evidence_object_ids_json, allen, source, reason, created_at, superseded_by
        FROM event_links
        WHERE superseded_by IS NULL
          AND (source_event_id IN (\(placeholders)) OR target_event_id IN (\(placeholders)))
        ORDER BY confidence DESC;
        """, eventIDs.map { .uuid($0) } + eventIDs.map { .uuid($0) })
        return rows.compactMap(decodeRow)
    }

    /// Distinct (source, target, relation) tuples already in the DB —
    /// the discoverer reads this to skip pairs it has already linked.
    public func existingTriples() async throws -> Set<String> {
        let rows = try await database.query("""
        SELECT source_event_id, target_event_id, relation FROM event_links
        WHERE superseded_by IS NULL;
        """, [])
        var out: Set<String> = []
        for row in rows {
            guard let s = row.uuid(0), let t = row.uuid(1), let r = row.string(2) else { continue }
            out.insert("\(s.uuidString)|\(t.uuidString)|\(r)")
        }
        return out
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> CausalLink? {
        guard
            let id = row.uuid(0),
            let source = row.uuid(1),
            let target = row.uuid(2),
            let relRaw = row.string(3),
            let relation = CausalRelation(rawValue: relRaw),
            let conf = row.double(4),
            let createdAt = row.double(9)
        else { return nil }
        let evidenceJSON = row.string(5) ?? "[]"
        let evidenceIDs: [KnowledgeObject.ID] = {
            guard let data = evidenceJSON.data(using: .utf8) else { return [] }
            return (try? decoder.decode([KnowledgeObject.ID].self, from: data)) ?? []
        }()
        let allen = row.string(6).flatMap(AllenRelation.init(rawValue:))
        let src = row.string(7).flatMap(CausalLinkSource.init(rawValue:)) ?? .heuristic
        let reason = row.string(8)
        let supersededBy = row.uuid(10)
        return CausalLink(
            id: id,
            sourceEventID: source,
            targetEventID: target,
            relation: relation,
            confidence: conf,
            evidenceObjectIDs: evidenceIDs,
            allen: allen,
            source: src,
            reason: reason,
            createdAt: Date(timeIntervalSince1970: createdAt),
            supersededBy: supersededBy
        )
    }
}
