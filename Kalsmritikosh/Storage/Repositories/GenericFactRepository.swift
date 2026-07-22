//
//  GenericFactRepository.swift
//  Kalsmritikosh
//
//  SEM — durable store for domain-pack GenericFacts. Facts are derived projections (never
//  primary evidence): each row keeps its source-block ids so it always drills back to
//  evidence. Idempotent upsert by fact id; lookup by subject+field for the answer layer.
//
//  Raw sqlite3 C-API repository style (exec/query + SQLValue/SQLRow).
//

import Foundation

public actor GenericFactRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    public func upsert(_ fact: GenericFact) async throws {
        let blocksJSON = String(data: try Self.encoder.encode(fact.sourceBlockIDs), encoding: .utf8) ?? "[]"
        try await database.exec("""
        INSERT OR REPLACE INTO generic_facts
            (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(fact.id),
            fact.subjectID.map { SQLValue.uuid($0) } ?? .null,
            .text(fact.subjectLabel), .text(fact.field), .text(fact.value),
            fact.unit.map { SQLValue.text($0) } ?? .null,
            .text(fact.status.rawValue), .real(fact.confidence),
            .text(blocksJSON), .real(Date().timeIntervalSince1970)
        ])
    }

    public func upsert(_ facts: [GenericFact]) async throws {
        for f in facts { try await upsert(f) }
    }

    /// Facts about a subject for a field (e.g. all "employer" facts for "Sasmal").
    public func facts(subjectLabel: String, field: String) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json
        FROM generic_facts WHERE subject_label = ? AND field = ? ORDER BY confidence DESC;
        """, [.text(subjectLabel), .text(FactSchemaRegistry.normalizeField(field))])
        return rows.compactMap(Self.decode)
    }

    /// Facts whose evidence intersects ANY of `blockIDs` — the query-time join
    /// (option A): once retrieval surfaces authoritative blocks, the facts derived
    /// from those exact blocks ride along. Matches on the JSON-encoded block-id
    /// array (uppercased UUID strings, as Foundation encodes them). Returns
    /// highest-confidence first, deduped by fact id.
    public func facts(forBlockIDs blockIDs: [UUID]) async throws -> [GenericFact] {
        let ids = Array(Set(blockIDs)).prefix(64)   // bound the OR-scan cost
        guard !ids.isEmpty else { return [] }
        let clauses = ids.map { _ in "source_blocks_json LIKE ?" }.joined(separator: " OR ")
        let binds = ids.map { SQLValue.text("%\($0.uuidString)%") }
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json
        FROM generic_facts WHERE \(clauses) ORDER BY confidence DESC;
        """, binds)
        return rows.compactMap(Self.decode)
    }

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM generic_facts;", [])).first?.int(0) ?? 0)
    }

    private nonisolated static func decode(_ r: SQLRow) -> GenericFact? {
        guard let id = r.uuid(0), let label = r.string(2), let field = r.string(3),
              let value = r.string(4), let statusRaw = r.string(6),
              let status = EvidenceStatus(rawValue: statusRaw) else { return nil }
        let blocks = (r.string(8)).flatMap { try? decoder.decode([UUID].self, from: Data($0.utf8)) } ?? []
        return GenericFact(id: id, subjectID: r.uuid(1), subjectLabel: label, field: field,
                           value: value, unit: r.string(5), status: status,
                           confidence: r.double(7) ?? 0, sourceBlockIDs: blocks)
    }
}
