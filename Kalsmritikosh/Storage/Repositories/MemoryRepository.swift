//
//  MemoryRepository.swift
//  Kalsmritikosh
//
//  Persists MemoryObjects and their change log. Used by MemoryDistiller
//  to rewrite the current snapshot; used by the MemoryRetriever (M6.12)
//  to answer questions before any lower layer is consulted.
//

import Foundation

public actor MemoryRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ memory: MemoryObject) async throws {
        let decisions = try encoder.encode(memory.keyDecisions)
        let eventIDs = try encoder.encode(memory.keyEventIDs)
        let relIDs = try encoder.encode(memory.importantRelationshipIDs)
        let risks = try encoder.encode(memory.risks)
        let sourceIDs = try encoder.encode(memory.sourceObjectIDs)

        try await database.exec("""
        INSERT INTO memory_objects (
            id, subject_kind, subject_identifier,
            key_decisions_json, key_event_ids_json,
            important_relationship_ids_json, risks_json,
            status, narrative, source_object_ids_json,
            confidence, version, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(subject_kind, subject_identifier) DO UPDATE SET
            key_decisions_json = excluded.key_decisions_json,
            key_event_ids_json = excluded.key_event_ids_json,
            important_relationship_ids_json = excluded.important_relationship_ids_json,
            risks_json = excluded.risks_json,
            status = excluded.status,
            narrative = excluded.narrative,
            source_object_ids_json = excluded.source_object_ids_json,
            confidence = excluded.confidence,
            version = excluded.version,
            updated_at = excluded.updated_at;
        """, [
            .uuid(memory.id),
            .text(memory.subjectKind.rawValue),
            .text(memory.subjectIdentifier),
            .text(String(data: decisions, encoding: .utf8) ?? "[]"),
            .text(String(data: eventIDs, encoding: .utf8) ?? "[]"),
            .text(String(data: relIDs, encoding: .utf8) ?? "[]"),
            .text(String(data: risks, encoding: .utf8) ?? "[]"),
            .text(memory.status),
            .text(memory.narrative),
            .text(String(data: sourceIDs, encoding: .utf8) ?? "[]"),
            .real(memory.confidence.value),
            .integer(Int64(memory.version)),
            .date(memory.createdAt),
            .date(memory.updatedAt)
        ])
    }

    public func recordChange(_ change: MemoryChange) async throws {
        let delta = try encoder.encode(change.delta)
        try await database.exec("""
        INSERT INTO memory_changes (
            id, memory_object_id, subject_kind, subject_identifier,
            prior_version, new_version, delta_json,
            triggering_object_id, occurred_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(change.id),
            .uuid(change.memoryObjectID),
            .text(change.subjectKind.rawValue),
            .text(change.subjectIdentifier),
            .integer(Int64(change.priorVersion)),
            .integer(Int64(change.newVersion)),
            .text(String(data: delta, encoding: .utf8) ?? "{}"),
            change.triggeringObjectID.map { .uuid($0) } ?? .null,
            .date(change.occurredAt)
        ])
    }

    public func current(forSubject kind: MemoryObject.SubjectKind, identifier: String) async throws -> MemoryObject? {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_identifier,
               key_decisions_json, key_event_ids_json,
               important_relationship_ids_json, risks_json,
               status, narrative, source_object_ids_json,
               confidence, version, created_at, updated_at
        FROM memory_objects
        WHERE subject_kind = ? AND subject_identifier = ?
        LIMIT 1;
        """, [.text(kind.rawValue), .text(identifier)])
        return rows.first.flatMap(decode)
    }

    public func search(_ query: String, limit: Int = 20) async throws -> [MemoryObject] {
        let pattern = "%\(query)%"
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_identifier,
               key_decisions_json, key_event_ids_json,
               important_relationship_ids_json, risks_json,
               status, narrative, source_object_ids_json,
               confidence, version, created_at, updated_at
        FROM memory_objects
        WHERE subject_identifier LIKE ? OR narrative LIKE ?
        ORDER BY updated_at DESC
        LIMIT ?;
        """, [.text(pattern), .text(pattern), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    public func changesSince(
        subjectKind kind: MemoryObject.SubjectKind?,
        subjectIdentifier identifier: String?,
        since: Date,
        limit: Int = 50
    ) async throws -> [MemoryChange] {
        let rows: [SQLRow]
        if let kind, let identifier {
            rows = try await database.query("""
            SELECT id, memory_object_id, subject_kind, subject_identifier,
                   prior_version, new_version, delta_json,
                   triggering_object_id, occurred_at
            FROM memory_changes
            WHERE subject_kind = ? AND subject_identifier = ? AND occurred_at >= ?
            ORDER BY occurred_at DESC
            LIMIT ?;
            """, [.text(kind.rawValue), .text(identifier), .date(since), .integer(Int64(limit))])
        } else {
            rows = try await database.query("""
            SELECT id, memory_object_id, subject_kind, subject_identifier,
                   prior_version, new_version, delta_json,
                   triggering_object_id, occurred_at
            FROM memory_changes
            WHERE occurred_at >= ?
            ORDER BY occurred_at DESC
            LIMIT ?;
            """, [.date(since), .integer(Int64(limit))])
        }
        return rows.compactMap(decodeChange)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM memory_objects;")
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Decoding

    private func decode(_ row: SQLRow) -> MemoryObject? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = MemoryObject.SubjectKind(rawValue: kindRaw),
            let identifier = row.string(2),
            let decisionsJSON = row.string(3),
            let eventIDsJSON = row.string(4),
            let relIDsJSON = row.string(5),
            let risksJSON = row.string(6),
            let status = row.string(7),
            let narrative = row.string(8),
            let sourceJSON = row.string(9),
            let conf = row.double(10),
            let version = row.int(11),
            let created = row.date(12),
            let updated = row.date(13)
        else { return nil }

        let decisions = decisionsJSON.data(using: .utf8)
            .flatMap { try? decoder.decode([MemoryObject.Decision].self, from: $0) } ?? []
        let eventIDs = eventIDsJSON.data(using: .utf8)
            .flatMap { try? decoder.decode([Event.ID].self, from: $0) } ?? []
        let relIDs = relIDsJSON.data(using: .utf8)
            .flatMap { try? decoder.decode([Relationship.ID].self, from: $0) } ?? []
        let risks = risksJSON.data(using: .utf8)
            .flatMap { try? decoder.decode([MemoryObject.Risk].self, from: $0) } ?? []
        let sources = sourceJSON.data(using: .utf8)
            .flatMap { try? decoder.decode([KnowledgeObject.ID].self, from: $0) } ?? []

        return MemoryObject(
            id: id,
            subjectKind: kind,
            subjectIdentifier: identifier,
            keyDecisions: decisions,
            keyEventIDs: eventIDs,
            importantRelationshipIDs: relIDs,
            risks: risks,
            status: status,
            narrative: narrative,
            sourceObjectIDs: sources,
            confidence: Confidence(conf),
            version: Int(version),
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeChange(_ row: SQLRow) -> MemoryChange? {
        guard
            let id = row.uuid(0),
            let memoryID = row.uuid(1),
            let kindRaw = row.string(2),
            let kind = MemoryObject.SubjectKind(rawValue: kindRaw),
            let identifier = row.string(3),
            let prior = row.int(4),
            let new = row.int(5),
            let deltaJSON = row.string(6),
            let occurred = row.date(8)
        else { return nil }

        let delta = deltaJSON.data(using: .utf8)
            .flatMap { try? decoder.decode(MemoryChange.Delta.self, from: $0) }
            ?? MemoryChange.Delta()

        return MemoryChange(
            id: id,
            memoryObjectID: memoryID,
            subjectKind: kind,
            subjectIdentifier: identifier,
            priorVersion: Int(prior),
            newVersion: Int(new),
            delta: delta,
            triggeringObjectID: row.uuid(7),
            occurredAt: occurred
        )
    }
}
