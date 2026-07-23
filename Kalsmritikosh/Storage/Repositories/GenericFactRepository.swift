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
        // Write from the CANONICAL assessment (S0.5 item 2, Commit C): dimension columns ←
        // assessment; status ← the compatibility encoding; legacy_status ← the preserved
        // original raw value (or the compatibility encoding when none). The dimensions are
        // NOT derived back from the compatibility status — that would discard explicit
        // review/origin/availability/conflict.
        let a = fact.assessment
        let enc = LegacyEvidenceStatusAdapter.encode(a)
        try await database.exec("""
        INSERT OR REPLACE INTO generic_facts
            (id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json, created_at,
             evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(fact.id),
            fact.subjectID.map { SQLValue.uuid($0) } ?? .null,
            .text(fact.subjectLabel), .text(fact.field), .text(fact.value),
            fact.unit.map { SQLValue.text($0) } ?? .null,
            .text(enc.rawValue), .real(fact.confidence),
            .text(blocksJSON), .real(Date().timeIntervalSince1970),
            .text(a.basis.rawValue), .text(a.review.rawValue), .text(a.origin.rawValue),
            .text(a.availability.rawValue), .text(a.conflict.rawValue),
            .text((a.legacyStatus ?? enc).rawValue)
        ])
    }

    public func upsert(_ facts: [GenericFact]) async throws {
        for f in facts { try await upsert(f) }
    }

    /// Facts about a subject for a field (e.g. all "employer" facts for "Sasmal").
    public func facts(subjectLabel: String, field: String) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
        FROM generic_facts WHERE subject_label = ? AND field = ? ORDER BY confidence DESC;
        """, [.text(subjectLabel), .text(FactSchemaRegistry.normalizeField(field))])
        return rows.compactMap(Self.decode)
    }

    /// HIST-033 — all typed facts about one canonical subject id, for history
    /// materialisation. Deterministic order (confidence desc, then id). Optional
    /// field filter (normalized). Facts whose subject_id is NULL are label-only
    /// and excluded from ID-scoped collection.
    public func facts(subjectID: UUID, fields: Set<String>? = nil) async throws -> [GenericFact] {
        let rows = try await database.query("""
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
        FROM generic_facts WHERE subject_id = ? ORDER BY confidence DESC, id ASC;
        """, [.uuid(subjectID)])
        let all = rows.compactMap(Self.decode)
        guard let fields, !fields.isEmpty else { return all }
        let wanted = Set(fields.map { FactSchemaRegistry.normalizeField($0) })
        return all.filter { wanted.contains(FactSchemaRegistry.normalizeField($0.field)) }
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
        SELECT id, subject_id, subject_label, field, value, unit, status, confidence, source_blocks_json,
               evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
        FROM generic_facts WHERE \(clauses) ORDER BY confidence DESC;
        """, binds)
        return rows.compactMap(Self.decode)
    }

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM generic_facts;", [])).first?.int(0) ?? 0)
    }

    private nonisolated static func decode(_ r: SQLRow) -> GenericFact? {
        // A row is only dropped when its IDENTITY/content is unusable — never because one
        // evidence DIMENSION is malformed (the decoder falls back per field).
        guard let id = r.uuid(0), let label = r.string(2), let field = r.string(3),
              let value = r.string(4) else { return nil }
        let blocks = (r.string(8)).flatMap { try? decoder.decode([UUID].self, from: Data($0.utf8)) } ?? []
        let assessment = EvidenceAssessmentRowDecoder.decode(.init(
            evidenceBasis: r.string(9), reviewDisposition: r.string(10), proposalOrigin: r.string(11),
            availabilityStatus: r.string(12), conflictStatus: r.string(13),
            legacyStatus: r.string(14), status: r.string(6)))
        return GenericFact(id: id, subjectID: r.uuid(1), subjectLabel: label, field: field,
                           value: value, unit: r.string(5), assessment: assessment,
                           confidence: r.double(7) ?? 0, sourceBlockIDs: blocks)
    }
}
