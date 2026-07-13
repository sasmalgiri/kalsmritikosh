//
//  ScreeningRepository.swift
//  Kalsmritikosh
//
//  Persona features (F9). Persists the research screening log + protocol. The
//  PRISMA-compatible counts are computed deterministically from the records
//  (PRISMACounts.from), never stored denormalized and never derived by an LLM.
//  Every exclusion must carry a reason (guarded here); decisions are
//  reversible (upsert), and the append-only WHY is recorded via the shared
//  review ledger by the caller.
//

import Foundation

public actor ScreeningRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Protocol

    public func setProtocol(_ json: String, forWorkspace id: Workspace.ID, at when: Date = Date()) async throws {
        try await database.exec("""
        INSERT INTO screening_protocols (workspace_id, protocol_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(workspace_id) DO UPDATE SET
            protocol_json = excluded.protocol_json,
            updated_at = excluded.updated_at;
        """, [.uuid(id), .text(json), .real(when.timeIntervalSince1970)])
    }

    public func getProtocol(forWorkspace id: Workspace.ID) async throws -> String? {
        let rows = try await database.query(
            "SELECT protocol_json FROM screening_protocols WHERE workspace_id = ? LIMIT 1;",
            [.uuid(id)]
        )
        return rows.first?.string(0)
    }

    // MARK: - Records

    /// Insert or update a record. An `.exclude` decision without a reason is
    /// rejected — every exclusion must be justified (§14.4).
    public func upsert(_ r: ScreeningRecord) async throws {
        if r.decision == .exclude, (r.exclusionReason?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            throw ScreeningError.exclusionNeedsReason
        }
        try await database.exec("""
        INSERT INTO screening_records
            (id, workspace_id, source_id, title, authors, year, stage, decision,
             exclusion_reason, reviewer, disagreement, notes, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            title = excluded.title,
            authors = excluded.authors,
            year = excluded.year,
            stage = excluded.stage,
            decision = excluded.decision,
            exclusion_reason = excluded.exclusion_reason,
            reviewer = excluded.reviewer,
            disagreement = excluded.disagreement,
            notes = excluded.notes,
            updated_at = excluded.updated_at;
        """, [
            .uuid(r.id),
            .uuid(r.workspaceID),
            r.sourceID.map { .uuid($0) } ?? .null,
            .text(r.title),
            r.authors.map { .text($0) } ?? .null,
            r.year.map { .integer(Int64($0)) } ?? .null,
            .text(r.stage.rawValue),
            .text(r.decision.rawValue),
            r.exclusionReason.map { .text($0) } ?? .null,
            .text(r.reviewer),
            .integer(r.disagreement ? 1 : 0),
            r.notes.map { .text($0) } ?? .null,
            .real(r.createdAt.timeIntervalSince1970),
            .real(r.updatedAt.timeIntervalSince1970)
        ])
    }

    public func records(inWorkspace id: Workspace.ID) async throws -> [ScreeningRecord] {
        let rows = try await database.query("""
        SELECT id, workspace_id, source_id, title, authors, year, stage, decision,
               exclusion_reason, reviewer, disagreement, notes, created_at, updated_at
        FROM screening_records WHERE workspace_id = ? ORDER BY created_at ASC;
        """, [.uuid(id)])
        return rows.compactMap(decode)
    }

    public func delete(_ id: ScreeningRecord.ID) async throws {
        try await database.exec("DELETE FROM screening_records WHERE id = ?;", [.uuid(id)])
    }

    /// Deterministic PRISMA-compatible counts for a workspace.
    public func counts(inWorkspace id: Workspace.ID) async throws -> PRISMACounts {
        PRISMACounts.from(try await records(inWorkspace: id))
    }

    // MARK: - Decode

    private func decode(_ row: SQLRow) -> ScreeningRecord? {
        guard
            let id = row.uuid(0),
            let workspaceID = row.uuid(1),
            let title = row.string(3),
            let stageRaw = row.string(6), let stage = ScreeningStage(rawValue: stageRaw),
            let decisionRaw = row.string(7), let decision = ScreeningDecision(rawValue: decisionRaw),
            let reviewer = row.string(9),
            let createdRaw = row.double(12),
            let updatedRaw = row.double(13)
        else { return nil }
        return ScreeningRecord(
            id: id,
            workspaceID: workspaceID,
            sourceID: row.uuid(2),
            title: title,
            authors: row.string(4),
            year: row.int(5).map(Int.init),
            stage: stage,
            decision: decision,
            exclusionReason: row.string(8),
            reviewer: reviewer,
            disagreement: (row.int(10) ?? 0) != 0,
            notes: row.string(11),
            createdAt: Date(timeIntervalSince1970: createdRaw),
            updatedAt: Date(timeIntervalSince1970: updatedRaw)
        )
    }
}

public enum ScreeningError: Error, LocalizedError {
    case exclusionNeedsReason
    public var errorDescription: String? {
        switch self {
        case .exclusionNeedsReason: return "Every exclusion must record a reason."
        }
    }
}
