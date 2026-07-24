//
//  AssertionsRepository.swift
//  Kalsmritikosh
//
//  Phase J.19 — Vol 17 §A3 substrate. Reads + writes for the
//  `assertions` table. Append-only on insert; retractions land via
//  a UPDATE setting `retracted_at` rather than DELETE, so the
//  history survives.
//

import Foundation

public actor AssertionsRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Writes

    public func insert(_ assertion: Assertion) async throws {
        let evidenceData = try encoder.encode(assertion.evidenceObjectIDs)
        let evidenceJSON = String(data: evidenceData, encoding: .utf8) ?? "[]"
        let blockData = try encoder.encode(assertion.evidenceBlockIDs)
        let blockJSON = String(data: blockData, encoding: .utf8) ?? "[]"
        let (objectValue, objectEntityID, objectEventID): (String?, UUID?, UUID?) = {
            switch assertion.object {
            case .entity(let id):   return (nil, id, nil)
            case .event(let id):    return (nil, nil, id)
            case .literal(let v):   return (v, nil, nil)
            }
        }()
        try await database.exec("""
        INSERT INTO assertions
            (id, subject_kind, subject_id, predicate,
             object_kind, object_value, object_entity_id, object_event_id,
             confidence, evidence_object_ids_json, agent, reason,
             recorded_at, retracted_at,
             evidence_block_ids_json, direct_quote, asserting_source_id,
             provenance, extractor_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(assertion.id),
            .text(assertion.subjectKind.rawValue),
            .uuid(assertion.subjectID),
            .text(assertion.predicate),
            .text(assertion.object.kindRaw),
            objectValue.map { .text($0) } ?? .null,
            objectEntityID.map { .uuid($0) } ?? .null,
            objectEventID.map { .uuid($0) } ?? .null,
            .real(assertion.confidence),
            .text(evidenceJSON),
            .text(assertion.agent),
            assertion.reason.map { .text($0) } ?? .null,
            .real(assertion.recordedAt.timeIntervalSince1970),
            assertion.retractedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .text(blockJSON),
            assertion.directQuote.map { .text($0) } ?? .null,
            assertion.assertingSourceID.map { .uuid($0) } ?? .null,
            .text(assertion.provenance.rawValue),
            .text(assertion.extractorVersion)
        ])
    }

    /// Retract an existing assertion. Reads filter on
    /// `retracted_at IS NULL`, so the row stops surfacing but the
    /// history remains queryable for audit.
    public func retract(_ id: Assertion.ID, at when: Date = Date()) async throws {
        try await database.exec(
            "UPDATE assertions SET retracted_at = ? WHERE id = ? AND retracted_at IS NULL;",
            [.real(when.timeIntervalSince1970), .uuid(id)]
        )
    }

    // MARK: - Reads

    /// Non-retracted assertions where the given subject is the
    /// subject. Most-recent-first.
    public func assertions(
        subjectKind: Assertion.SubjectKind,
        subjectID: UUID,
        limit: Int = 50
    ) async throws -> [Assertion] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, predicate,
               object_kind, object_value, object_entity_id, object_event_id,
               confidence, evidence_object_ids_json, agent, reason,
               recorded_at, retracted_at,
               evidence_block_ids_json, direct_quote, asserting_source_id,
               provenance, extractor_version
        FROM assertions
        WHERE subject_kind = ? AND subject_id = ? AND retracted_at IS NULL
        ORDER BY recorded_at DESC
        LIMIT ?;
        """, [
            .text(subjectKind.rawValue),
            .uuid(subjectID),
            .integer(Int64(limit))
        ])
        return rows.compactMap(decodeRow)
    }

    public func recent(limit: Int = 100) async throws -> [Assertion] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, predicate,
               object_kind, object_value, object_entity_id, object_event_id,
               confidence, evidence_object_ids_json, agent, reason,
               recorded_at, retracted_at,
               evidence_block_ids_json, direct_quote, asserting_source_id,
               provenance, extractor_version
        FROM assertions
        WHERE retracted_at IS NULL
        ORDER BY recorded_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decodeRow)
    }

    /// Deterministic paged enumeration of a SUBJECT's non-retracted assertions (no fixed
    /// ceiling — the incremental producer pages through all of them).
    public func assertions(subjectKind: Assertion.SubjectKind, subjectID: UUID,
                           offset: Int, pageSize: Int) async throws -> [Assertion] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, predicate,
               object_kind, object_value, object_entity_id, object_event_id,
               confidence, evidence_object_ids_json, agent, reason,
               recorded_at, retracted_at,
               evidence_block_ids_json, direct_quote, asserting_source_id,
               provenance, extractor_version
        FROM assertions WHERE subject_kind = ? AND subject_id = ? AND retracted_at IS NULL
        ORDER BY id ASC LIMIT ? OFFSET ?;
        """, [.text(subjectKind.rawValue), .uuid(subjectID), .integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap(decodeRow)
    }

    /// Keyset page (`id > afterID ORDER BY id`) of non-retracted assertions (resumable backfill).
    public func page(afterID: UUID?, pageSize: Int) async throws -> [Assertion] {
        let cols = """
        SELECT id, subject_kind, subject_id, predicate,
               object_kind, object_value, object_entity_id, object_event_id,
               confidence, evidence_object_ids_json, agent, reason,
               recorded_at, retracted_at,
               evidence_block_ids_json, direct_quote, asserting_source_id,
               provenance, extractor_version
        FROM assertions
        """
        let rows: [SQLRow]
        if let afterID {
            rows = try await database.query("\(cols) WHERE retracted_at IS NULL AND id > ? ORDER BY id ASC LIMIT ?;",
                                            [.uuid(afterID), .integer(Int64(pageSize))])
        } else {
            rows = try await database.query("\(cols) WHERE retracted_at IS NULL ORDER BY id ASC LIMIT ?;",
                                            [.integer(Int64(pageSize))])
        }
        return rows.compactMap(decodeRow)
    }

    /// Deterministic paged enumeration of ALL non-retracted assertions (Claim-producer backfill).
    public func all(offset: Int = 0, pageSize: Int = 1_000) async throws -> [Assertion] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, predicate,
               object_kind, object_value, object_entity_id, object_event_id,
               confidence, evidence_object_ids_json, agent, reason,
               recorded_at, retracted_at,
               evidence_block_ids_json, direct_quote, asserting_source_id,
               provenance, extractor_version
        FROM assertions WHERE retracted_at IS NULL
        ORDER BY id ASC LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap(decodeRow)
    }

    public func count(includeRetracted: Bool = false) async throws -> Int {
        let sql = includeRetracted
            ? "SELECT COUNT(*) FROM assertions;"
            : "SELECT COUNT(*) FROM assertions WHERE retracted_at IS NULL;"
        let rows = try await database.query(sql, [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> Assertion? {
        guard
            let id = row.uuid(0),
            let subjectKindRaw = row.string(1),
            let subjectKind = Assertion.SubjectKind(rawValue: subjectKindRaw),
            let subjectID = row.uuid(2),
            let predicate = row.string(3),
            let objectKindRaw = row.string(4),
            let conf = row.double(8),
            let agent = row.string(10),
            let recordedAtRaw = row.double(12)
        else { return nil }
        let object: Assertion.Object
        switch objectKindRaw {
        case "entity":
            guard let oid = row.uuid(6) else { return nil }
            object = .entity(oid)
        case "event":
            guard let oid = row.uuid(7) else { return nil }
            object = .event(oid)
        case "literal":
            object = .literal(row.string(5) ?? "")
        default:
            return nil
        }
        let evidenceJSON = row.string(9) ?? "[]"
        let evidence: [KnowledgeObject.ID] = {
            guard let data = evidenceJSON.data(using: .utf8) else { return [] }
            return (try? decoder.decode([KnowledgeObject.ID].self, from: data)) ?? []
        }()
        let retracted = row.double(13).map { Date(timeIntervalSince1970: $0) }
        // A5.2 columns (nullable / defaulted; older rows decode to defaults).
        let blockJSON = row.string(14) ?? "[]"
        let blocks: [EvidenceBlock.ID] = {
            guard let data = blockJSON.data(using: .utf8) else { return [] }
            return (try? decoder.decode([EvidenceBlock.ID].self, from: data)) ?? []
        }()
        let provenance = row.string(17).flatMap(Assertion.Provenance.init(rawValue:)) ?? .sourceAsserted
        return Assertion(
            id: id,
            subjectKind: subjectKind,
            subjectID: subjectID,
            predicate: predicate,
            object: object,
            confidence: conf,
            evidenceObjectIDs: evidence,
            evidenceBlockIDs: blocks,
            directQuote: row.string(15),
            assertingSourceID: row.uuid(16),
            provenance: provenance,
            extractorVersion: row.string(18) ?? "v1",
            agent: agent,
            reason: row.string(11),
            recordedAt: Date(timeIntervalSince1970: recordedAtRaw),
            retractedAt: retracted
        )
    }
}
