//
//  ContradictionsRepository.swift
//  Kalsmritikosh
//
//  System 3 — persists detected conflicts (schema v31 `contradictions`).
//  Conflicts accumulate in the ledger instead of being recomputed per
//  query. Derived data: a re-scan clears and replaces the open set, so
//  `clear()` is safe. Per the evidence-gate contract both sides + their
//  evidence are always retained; nothing is averaged away.
//

import Foundation

public actor ContradictionsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ c: Contradiction) async {
        try? await database.exec("""
        INSERT OR IGNORE INTO contradictions
            (id, kind, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(c.id),
            .text(c.kind.rawValue),
            .text(c.description),
            .text(c.claimA),
            .text(c.claimB),
            c.evidenceA.map { .uuid($0) } ?? .null,
            c.evidenceB.map { .uuid($0) } ?? .null,
            .text(c.severity.rawValue),
            .text(c.status.rawValue),
            .real(c.detectedAt.timeIntervalSince1970)
        ])
    }

    public func insertMany(_ items: [Contradiction]) async {
        for c in items { await insert(c) }
    }

    /// Open (unresolved) conflicts, most severe first.
    public func open(limit: Int = 500) async -> [Contradiction] {
        let rows = (try? await database.query("""
        SELECT id, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at, kind
        FROM contradictions WHERE status = 'open'
        ORDER BY
            CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
            detected_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap(decode)
    }

    public func all(limit: Int = 500) async -> [Contradiction] {
        let rows = (try? await database.query("""
        SELECT id, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at, kind
        FROM contradictions
        ORDER BY detected_at DESC LIMIT ?;
        """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap(decode)
    }

    public func setStatus(_ id: UUID, _ status: Contradiction.Status) async {
        try? await database.exec(
            "UPDATE contradictions SET status = ? WHERE id = ?;",
            [.text(status.rawValue), .uuid(id)]
        )
    }

    /// Clear all conflicts (a re-scan replaces the open set). Derived, safe.
    public func clear() async {
        try? await database.exec("DELETE FROM contradictions;", [])
    }

    public func count() async -> Int {
        let rows = (try? await database.query(
            "SELECT COUNT(*) FROM contradictions WHERE status = 'open';", [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Decode

    private func decode(_ row: SQLRow) -> Contradiction? {
        guard
            let id = row.uuid(0),
            let description = row.string(1),
            let claimA = row.string(2),
            let claimB = row.string(3),
            let severityRaw = row.string(6),
            let severity = Contradiction.Severity(rawValue: severityRaw),
            let statusRaw = row.string(7),
            let status = Contradiction.Status(rawValue: statusRaw),
            let detectedAtRaw = row.double(8)
        else { return nil }
        let kind = row.string(9).flatMap(Contradiction.Kind.init(rawValue:)) ?? .other
        return Contradiction(
            id: id,
            kind: kind,
            description: description,
            claimA: claimA,
            claimB: claimB,
            evidenceA: row.uuid(4),
            evidenceB: row.uuid(5),
            severity: severity,
            status: status,
            detectedAt: Date(timeIntervalSince1970: detectedAtRaw)
        )
    }
}
