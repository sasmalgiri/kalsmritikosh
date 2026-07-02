//
//  GapNodeRepository.swift
//  Kalsmritikosh
//
//  System 3 — persists inferred missing-evidence gap nodes (schema v31).
//  A gap is never a factual claim: it's a flagged expected-but-missing
//  document, always low-confidence and reasoned, shown as "likely
//  missing". Historiographical silence discipline: a gap ≠ a negation.
//

import Foundation

public actor GapNodeRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ gap: GapNode) async {
        try? await database.exec("""
        INSERT OR IGNORE INTO gap_nodes
            (id, kind, description, reason, confidence, near_entity,
             before_event, after_event, evidence_object_id, detected_at, dismissed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(gap.id),
            .text(gap.kind.rawValue),
            .text(gap.description),
            .text(gap.reason),
            .real(gap.confidence),
            gap.nearEntity.map { .text($0) } ?? .null,
            gap.beforeEvent.map { .uuid($0) } ?? .null,
            gap.afterEvent.map { .uuid($0) } ?? .null,
            gap.evidenceObjectID.map { .uuid($0) } ?? .null,
            .real(gap.detectedAt.timeIntervalSince1970),
            .integer(gap.dismissed ? 1 : 0)
        ])
    }

    public func insertMany(_ gaps: [GapNode]) async {
        for g in gaps { await insert(g) }
    }

    public func all(includeDismissed: Bool = false, limit: Int = 500) async -> [GapNode] {
        let sql = includeDismissed
            ? "SELECT id, kind, description, reason, confidence, near_entity, before_event, after_event, evidence_object_id, detected_at, dismissed FROM gap_nodes ORDER BY confidence DESC, detected_at DESC LIMIT ?;"
            : "SELECT id, kind, description, reason, confidence, near_entity, before_event, after_event, evidence_object_id, detected_at, dismissed FROM gap_nodes WHERE dismissed = 0 ORDER BY confidence DESC, detected_at DESC LIMIT ?;"
        let rows = (try? await database.query(sql, [.integer(Int64(limit))])) ?? []
        return rows.compactMap(decode)
    }

    public func forEntity(_ entity: String, limit: Int = 100) async -> [GapNode] {
        let rows = (try? await database.query("""
        SELECT id, kind, description, reason, confidence, near_entity, before_event, after_event, evidence_object_id, detected_at, dismissed
        FROM gap_nodes WHERE near_entity = ? AND dismissed = 0
        ORDER BY confidence DESC LIMIT ?;
        """, [.text(entity), .integer(Int64(limit))])) ?? []
        return rows.compactMap(decode)
    }

    public func dismiss(_ id: UUID) async {
        try? await database.exec("UPDATE gap_nodes SET dismissed = 1 WHERE id = ?;", [.uuid(id)])
    }

    /// Clear all gaps (a re-scan replaces them). Gaps are derived, so
    /// this is safe.
    public func clear() async {
        try? await database.exec("DELETE FROM gap_nodes;", [])
    }

    public func count() async -> Int {
        let rows = (try? await database.query("SELECT COUNT(*) FROM gap_nodes WHERE dismissed = 0;", [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Decode

    private func decode(_ row: SQLRow) -> GapNode? {
        guard let id = row.uuid(0),
              let kindRaw = row.string(1),
              let kind = GapKind(rawValue: kindRaw),
              let description = row.string(2),
              let reason = row.string(3),
              let detectedAtRaw = row.double(9)
        else { return nil }
        return GapNode(
            id: id,
            kind: kind,
            description: description,
            reason: reason,
            confidence: row.double(4) ?? 0.3,
            nearEntity: row.string(5),
            beforeEvent: row.uuid(6),
            afterEvent: row.uuid(7),
            evidenceObjectID: row.uuid(8),
            detectedAt: Date(timeIntervalSince1970: detectedAtRaw),
            dismissed: (row.int(10) ?? 0) == 1
        )
    }
}
