//
//  CaseBriefingRepository.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), AI-18 — the ledger rows a case briefing is built from,
//  read for exactly the case's cleared documents. Every row keeps the document (KnowledgeObject id) it
//  came from, so the briefing can tie each line to the number the reader and the verifier use. Reads
//  only; nothing here writes.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

public actor CaseBriefingRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The most rows read per section; the briefing states how many more there were (no silent cap).
    public static let rowsPerSection = 600
    /// Ids bound per IN (…) list (SQLite's variable limit is far higher; this keeps statements small).
    static let chunk = 400

    public func material(objectIDs: [UUID], versionToObject: [UUID: UUID]) async throws -> CaseLedgerBriefing.Material {
        var m = CaseLedgerBriefing.Material()
        guard !objectIDs.isEmpty else { return m }
        let ids = objectIDs.sorted { $0.uuidString < $1.uuidString }
        let idSet = Set(ids)

        // People and organisations (+ aliases, tier).
        var entityIDs: [UUID: CaseLedgerBriefing.Entity] = [:]
        try await each(ids) { list, binds in
            let rows = try await self.database.query("""
            SELECT id, kind, value, quality_tier, source_object_id, confidence FROM entities
            WHERE source_object_id IN (\(list)) ORDER BY value LIMIT \(Self.rowsPerSection + 1);
            """, binds)
            for r in rows {
                guard let id = r.uuid(0), let source = r.uuid(4) else { continue }
                entityIDs[id] = CaseLedgerBriefing.Entity(id: id, kind: r.string(1) ?? "", value: r.string(2) ?? "",
                                                    tier: r.string(3) ?? "T2", source: source, confidence: r.double(5) ?? 0.5,
                                                    aliases: [])
            }
        }
        if !entityIDs.isEmpty {
            let eids = Array(entityIDs.keys).sorted { $0.uuidString < $1.uuidString }
            try await each(eids) { list, binds in
                for r in try await self.database.query("SELECT entity_id, alias_normalized FROM entity_aliases WHERE entity_id IN (\(list));", binds) {
                    guard let id = r.uuid(0), let alias = r.string(1), var e = entityIDs[id] else { continue }
                    if !e.aliases.contains(alias), alias.lowercased() != e.value.lowercased() { e.aliases.append(alias) }
                    entityIDs[id] = e
                }
            }
        }
        m.entities = entityIDs.values.sorted { $0.value.lowercased() != $1.value.lowercased() ? $0.value.lowercased() < $1.value.lowercased() : $0.id.uuidString < $1.id.uuidString }

        // Dated events (date confidence stands for precision: low = approximate).
        try await each(ids) { list, binds in
            for r in try await self.database.query("""
            SELECT id, kind, date, end_date, title, summary, source_object_id, date_confidence, quality_tier FROM events
            WHERE source_object_id IN (\(list)) ORDER BY date LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let id = r.uuid(0), let source = r.uuid(6), let date = r.double(2) else { continue }
                m.events.append(CaseLedgerBriefing.Event(id: id, kind: r.string(1) ?? "", date: Date(timeIntervalSince1970: date),
                                                   endDate: r.double(3).map { Date(timeIntervalSince1970: $0) },
                                                   title: r.string(4) ?? "", summary: r.string(5), source: source,
                                                   dateConfidence: r.double(7) ?? 0.5, tier: r.string(8) ?? "T2"))
            }
        }
        m.events.sort { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }

        // Relationships between the case's entities.
        try await each(ids) { list, binds in
            for r in try await self.database.query("""
            SELECT r.kind, a.value, b.value, r.source_object_id FROM relationships r
            JOIN entities a ON a.id = r.from_entity_id JOIN entities b ON b.id = r.to_entity_id
            WHERE r.source_object_id IN (\(list)) LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let source = r.uuid(3) else { continue }
                m.relationships.append(CaseLedgerBriefing.Relationship(kind: r.string(0) ?? "", from: r.string(1) ?? "", to: r.string(2) ?? "", source: source))
            }
        }

        // Typed fields (document numbers, dates, amounts …), by the version they were read from.
        let versions = versionToObject.keys.sorted { $0.uuidString < $1.uuidString }
        try await each(versions) { list, binds in
            for r in try await self.database.query("""
            SELECT source_version_id, field_type, normalized_value, confidence, extraction_method FROM typed_fields
            WHERE source_version_id IN (\(list)) ORDER BY field_type, normalized_value LIMIT \(Self.rowsPerSection + 1);
            """, binds) {
                guard let v = r.uuid(0), let source = versionToObject[v] else { continue }
                m.fields.append(CaseLedgerBriefing.Field(type: r.string(1) ?? "", value: r.string(2) ?? "", confidence: r.double(3) ?? 0.5,
                                                   method: r.string(4) ?? "", source: source))
            }
        }

        // Domain facts — their source blocks resolve to the owning document.
        var blockOwner: [UUID: UUID] = [:]
        try await each(ids) { list, binds in
            for r in try await self.database.query("SELECT id, document_id FROM evidence_blocks WHERE document_id IN (\(list));", binds) {
                if let b = r.uuid(0), let d = r.uuid(1) { blockOwner[b] = d }
            }
        }
        if !blockOwner.isEmpty {
            let rows = try await database.query("""
            SELECT subject_label, field, value, unit, status, confidence, source_blocks_json FROM generic_facts
            ORDER BY subject_label, field LIMIT 20000;
            """)
            for r in rows where m.facts.count <= Self.rowsPerSection {
                let blocks = Self.uuids(json: r.string(6))
                guard let source = blocks.lazy.compactMap({ blockOwner[$0] }).first else { continue }
                m.facts.append(CaseLedgerBriefing.Fact(subject: r.string(0) ?? "", field: r.string(1) ?? "", value: r.string(2) ?? "",
                                                 unit: r.string(3), status: r.string(4) ?? "", confidence: r.double(5) ?? 0.5, source: source))
            }
        }

        // Statements (who said what) — assertions whose evidence is a case document.
        for r in try await database.query("""
        SELECT subject_kind, subject_id, predicate, object_value, evidence_object_ids_json, confidence, agent FROM assertions
        WHERE retracted_at IS NULL ORDER BY recorded_at LIMIT 20000;
        """) where m.statements.count <= Self.rowsPerSection {
            guard let source = Self.uuids(json: r.string(4)).first(where: { idSet.contains($0) }) else { continue }
            let subject = r.uuid(1).flatMap { entityIDs[$0]?.value } ?? (r.string(1) ?? "")
            m.statements.append(CaseLedgerBriefing.Statement(subject: subject, predicate: r.string(2) ?? "", object: r.string(3) ?? "",
                                                       agent: r.string(6) ?? "", confidence: r.double(5) ?? 0.5, source: source))
        }

        // Contradictions already found between case documents.
        for r in try await database.query("""
        SELECT description, claim_a, claim_b, evidence_a, evidence_b, severity, status FROM contradictions
        WHERE status != 'resolved' ORDER BY detected_at LIMIT 20000;
        """) where m.contradictions.count <= Self.rowsPerSection {
            let a = r.string(3).flatMap(UUID.init(uuidString:)), b = r.string(4).flatMap(UUID.init(uuidString:))
            guard let a, idSet.contains(a) || (b.map { idSet.contains($0) } ?? false) else { continue }
            m.contradictions.append(CaseLedgerBriefing.Contradiction(description: r.string(0) ?? "", claimA: r.string(1) ?? "", claimB: r.string(2) ?? "",
                                                               sourceA: a, sourceB: b.flatMap { idSet.contains($0) ? $0 : nil },
                                                               severity: r.string(5) ?? ""))
        }

        // Memory objects and summaries scoped to case documents.
        for r in try await database.query("""
        SELECT subject_kind, subject_identifier, narrative, source_object_ids_json, confidence FROM memory_objects
        WHERE status = 'active' AND narrative != '' ORDER BY subject_identifier LIMIT 20000;
        """) where m.memory.count <= Self.rowsPerSection {
            let sources = Self.uuids(json: r.string(3)).filter { idSet.contains($0) }
            guard !sources.isEmpty else { continue }
            m.memory.append(CaseLedgerBriefing.Memory(subject: (r.string(0) ?? "") + " " + (r.string(1) ?? ""), narrative: r.string(2) ?? "",
                                                sources: sources, confidence: r.double(4) ?? 0.5))
        }
        for r in try await database.query("SELECT level, scope_json, body, confidence FROM summaries ORDER BY produced_at DESC LIMIT 20000;")
        where m.summaries.count <= Self.rowsPerSection {
            let sources = Self.uuids(json: r.string(1)).filter { idSet.contains($0) }
            guard !sources.isEmpty, let body = r.string(2), !body.isEmpty else { continue }
            m.summaries.append(CaseLedgerBriefing.Summary(level: r.string(0) ?? "", body: body, sources: sources, confidence: r.double(3) ?? 0.5))
        }
        return m
    }

    /// Run `body` over `ids` in chunks, with the "?, ?, …" list and its bindings.
    private func each(_ ids: [UUID], _ body: (String, [SQLValue]) async throws -> Void) async throws {
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(ids.count, start + Self.chunk)])
            try await body(Array(repeating: "?", count: slice.count).joined(separator: ", "), slice.map { .uuid($0) })
            start += Self.chunk
        }
    }

    /// Every UUID written anywhere in a JSON text (arrays of ids, or objects carrying them).
    static func uuids(json: String?) -> [UUID] {
        guard let json, !json.isEmpty else { return [] }
        var out: [UUID] = [], seen = Set<UUID>()
        let pattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        for match in json.matches(of: pattern) {
            if let id = UUID(uuidString: String(match.output)), seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}
