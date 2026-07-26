//
//  WorkspaceRepository.swift
//  Kalsmritikosh
//
//  Persona features Epic 1 (F1). Row-level access to `workspaces` and its
//  membership tables. A workspace is a FILTERED VIEW over the one ledger:
//  membership rows point at existing files/entities and never copy content.
//  Removing a membership row NEVER deletes evidence (§6.4 acceptance).
//

import Foundation

public actor WorkspaceRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Workspaces

    public func upsert(_ ws: Workspace) async throws {
        try await database.exec("""
        INSERT INTO workspaces
            (id, title, template_type, description, status, default_date_start,
             default_date_end, default_scope_json, created_at, updated_at, archived_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            template_type = excluded.template_type,
            description = excluded.description,
            status = excluded.status,
            default_date_start = excluded.default_date_start,
            default_date_end = excluded.default_date_end,
            default_scope_json = excluded.default_scope_json,
            updated_at = excluded.updated_at,
            archived_at = excluded.archived_at;
        """, [
            .uuid(ws.id),
            .text(ws.title),
            .text(ws.template.rawValue),
            ws.description.map { .text($0) } ?? .null,
            .text(ws.status.rawValue),
            ws.defaultDateStart.map { .real($0.timeIntervalSince1970) } ?? .null,
            ws.defaultDateEnd.map { .real($0.timeIntervalSince1970) } ?? .null,
            .text(ws.defaultScopeJSON),
            .real(ws.createdAt.timeIntervalSince1970),
            .real(ws.updatedAt.timeIntervalSince1970),
            ws.archivedAt.map { .real($0.timeIntervalSince1970) } ?? .null
        ])
    }

    public func find(_ id: Workspace.ID) async throws -> Workspace? {
        let rows = try await database.query("""
        SELECT id, title, template_type, description, status, default_date_start,
               default_date_end, default_scope_json, created_at, updated_at, archived_at
        FROM workspaces WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        return rows.first.flatMap(decode)
    }

    /// Active workspaces first, most-recently-updated on top; archived last.
    public func all(includeArchived: Bool = true) async throws -> [Workspace] {
        let sql = includeArchived
            ? "SELECT id, title, template_type, description, status, default_date_start, default_date_end, default_scope_json, created_at, updated_at, archived_at FROM workspaces ORDER BY (status = 'archived') ASC, updated_at DESC;"
            : "SELECT id, title, template_type, description, status, default_date_start, default_date_end, default_scope_json, created_at, updated_at, archived_at FROM workspaces WHERE status != 'archived' ORDER BY updated_at DESC;"
        let rows = try await database.query(sql)
        return rows.compactMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM workspaces;")
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Archive (soft) — reproducible later, never destroyed (§6.4).
    public func setStatus(_ id: Workspace.ID, to status: WorkspaceStatus, at when: Date = Date()) async throws {
        try await database.exec(
            "UPDATE workspaces SET status = ?, archived_at = ?, updated_at = ? WHERE id = ?;",
            [
                .text(status.rawValue),
                status == .archived ? .real(when.timeIntervalSince1970) : .null,
                .real(when.timeIntervalSince1970),
                .uuid(id)
            ]
        )
    }

    /// Hard delete of the workspace + its membership/tags/views (via cascade).
    /// The referenced files/entities/evidence are untouched.
    public func delete(_ id: Workspace.ID) async throws {
        try await database.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - Source membership

    public func addSource(_ fileID: UUID, to workspaceID: Workspace.ID, at when: Date = Date()) async throws {
        try await database.exec("""
        INSERT INTO workspace_sources (workspace_id, file_id, added_at)
        VALUES (?, ?, ?)
        ON CONFLICT(workspace_id, file_id) DO NOTHING;
        """, [.uuid(workspaceID), .uuid(fileID), .real(when.timeIntervalSince1970)])
    }

    /// PA-UI-001 — atomically add several sources and bump the workspace's `updated_at`, so a
    /// multi-select add is one all-or-nothing membership change.
    public func addSources(_ fileIDs: [UUID], to workspaceID: Workspace.ID, at when: Date = Date()) async throws {
        guard !fileIDs.isEmpty else { return }
        let sp = "wsaddsrc_\(workspaceID.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);", [])
            for fileID in fileIDs {
                try await database.exec("""
                INSERT INTO workspace_sources (workspace_id, file_id, added_at)
                VALUES (?, ?, ?) ON CONFLICT(workspace_id, file_id) DO NOTHING;
                """, [.uuid(workspaceID), .uuid(fileID), .real(when.timeIntervalSince1970)])
            }
            try await database.exec(
                "UPDATE workspaces SET updated_at = ? WHERE id = ?;",
                [.real(when.timeIntervalSince1970), .uuid(workspaceID)])
            try await database.exec("RELEASE SAVEPOINT \(sp);", [])
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);", [])
            try? await database.exec("RELEASE SAVEPOINT \(sp);", [])
            throw error
        }
    }

    /// Bump `updated_at` without any other change (e.g. after a membership edit).
    public func touch(_ id: Workspace.ID, at when: Date = Date()) async throws {
        try await database.exec(
            "UPDATE workspaces SET updated_at = ? WHERE id = ?;",
            [.real(when.timeIntervalSince1970), .uuid(id)])
    }

    /// Removes membership only — the file + its extracted evidence remain.
    public func removeSource(_ fileID: UUID, from workspaceID: Workspace.ID) async throws {
        try await database.exec(
            "DELETE FROM workspace_sources WHERE workspace_id = ? AND file_id = ?;",
            [.uuid(workspaceID), .uuid(fileID)]
        )
    }

    public func sourceIDs(in workspaceID: Workspace.ID) async throws -> [UUID] {
        let rows = try await database.query(
            "SELECT file_id FROM workspace_sources WHERE workspace_id = ? ORDER BY added_at DESC;",
            [.uuid(workspaceID)]
        )
        return rows.compactMap { $0.uuid(0) }
    }

    public func sourceCount(in workspaceID: Workspace.ID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM workspace_sources WHERE workspace_id = ?;",
            [.uuid(workspaceID)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Every workspace a given source belongs to (a source may be in many).
    public func workspaceIDs(forSource fileID: UUID) async throws -> [Workspace.ID] {
        let rows = try await database.query(
            "SELECT workspace_id FROM workspace_sources WHERE file_id = ?;",
            [.uuid(fileID)]
        )
        return rows.compactMap { $0.uuid(0) }
    }

    /// Returns the subset of `objectIDs` (KnowledgeObject IDs) that belong to
    /// `workspaceID` via the knowledge_objects.file_id → workspace_sources link.
    /// Used by SensitiveRetrievalPolicy for cross-workspace enforcement.
    /// Returns an empty set when `objectIDs` is empty.
    public func koIDsInWorkspace(_ objectIDs: [UUID], workspaceID: UUID) async throws -> Set<UUID> {
        guard !objectIDs.isEmpty else { return [] }
        let placeholders = objectIDs.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query("""
            SELECT ko.id FROM knowledge_objects ko
            INNER JOIN workspace_sources ws ON ws.file_id = ko.file_id
            WHERE ko.id IN (\(placeholders)) AND ws.workspace_id = ?;
            """,
            objectIDs.map { .uuid($0) } + [.uuid(workspaceID)]
        )
        return Set(rows.compactMap { $0.uuid(0) })
    }

    /// Returns the subset of `entityIDs` that are members of `workspaceID`
    /// (direct assignments in workspace_entities). Used by SensitiveRetrievalPolicy.
    public func entityIDsInWorkspace(_ entityIDs: [UUID], workspaceID: UUID) async throws -> Set<UUID> {
        guard !entityIDs.isEmpty else { return [] }
        let placeholders = entityIDs.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query("""
            SELECT entity_id FROM workspace_entities
            WHERE workspace_id = ? AND entity_id IN (\(placeholders));
            """,
            [.uuid(workspaceID)] + entityIDs.map { .uuid($0) }
        )
        return Set(rows.compactMap { $0.uuid(0) })
    }

    // MARK: - Entity membership

    public func addEntity(_ entityID: UUID, to workspaceID: Workspace.ID, at when: Date = Date()) async throws {
        try await database.exec("""
        INSERT INTO workspace_entities (workspace_id, entity_id, added_at)
        VALUES (?, ?, ?)
        ON CONFLICT(workspace_id, entity_id) DO NOTHING;
        """, [.uuid(workspaceID), .uuid(entityID), .real(when.timeIntervalSince1970)])
    }

    public func removeEntity(_ entityID: UUID, from workspaceID: Workspace.ID) async throws {
        try await database.exec(
            "DELETE FROM workspace_entities WHERE workspace_id = ? AND entity_id = ?;",
            [.uuid(workspaceID), .uuid(entityID)]
        )
    }

    /// Workspace subjects = the UNION of manually-curated (`workspace_entities`) and
    /// automatically-derived (`workspace_derived_entities`) membership. A subject that is both
    /// manual and derived appears once.
    public func entityIDs(in workspaceID: Workspace.ID) async throws -> [UUID] {
        let rows = try await database.query("""
        SELECT entity_id FROM workspace_entities         WHERE workspace_id = ?
        UNION
        SELECT entity_id FROM workspace_derived_entities WHERE workspace_id = ?
        ORDER BY entity_id ASC;
        """, [.uuid(workspaceID), .uuid(workspaceID)])
        return rows.compactMap { $0.uuid(0) }
    }

    /// Only the automatically-derived subjects (for reconciliation).
    public func derivedEntityIDs(in workspaceID: Workspace.ID) async throws -> [UUID] {
        (try await database.query(
            "SELECT entity_id FROM workspace_derived_entities WHERE workspace_id = ? ORDER BY entity_id ASC;",
            [.uuid(workspaceID)])).compactMap { $0.uuid(0) }
    }

    /// Replace the DERIVED membership set for a workspace atomically — add missing, drop
    /// obsolete — while leaving manually-added `workspace_entities` untouched.
    public func replaceDerivedEntities(_ expected: Set<UUID>, in workspaceID: Workspace.ID, at when: Date = Date()) async throws {
        let sp = "wsderiv_\(workspaceID.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);", [])
            let existing = Set(try await derivedEntityIDs(in: workspaceID))
            for obsolete in existing.subtracting(expected) {
                try await database.exec(
                    "DELETE FROM workspace_derived_entities WHERE workspace_id = ? AND entity_id = ?;",
                    [.uuid(workspaceID), .uuid(obsolete)])
            }
            for add in expected.subtracting(existing) {
                try await database.exec("""
                INSERT INTO workspace_derived_entities (workspace_id, entity_id, derived_at)
                VALUES (?,?,?) ON CONFLICT(workspace_id, entity_id) DO NOTHING;
                """, [.uuid(workspaceID), .uuid(add), .real(when.timeIntervalSince1970)])
            }
            try await database.exec("RELEASE SAVEPOINT \(sp);", [])
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);", [])
            try? await database.exec("RELEASE SAVEPOINT \(sp);", [])
            throw error
        }
    }

    // MARK: - Decode

    private func decode(_ row: SQLRow) -> Workspace? {
        guard
            let id = row.uuid(0),
            let title = row.string(1),
            let templateRaw = row.string(2),
            let template = WorkspaceTemplate(rawValue: templateRaw),
            let statusRaw = row.string(4),
            let status = WorkspaceStatus(rawValue: statusRaw),
            let scopeJSON = row.string(7),
            let createdRaw = row.double(8),
            let updatedRaw = row.double(9)
        else { return nil }
        return Workspace(
            id: id,
            title: title,
            template: template,
            description: row.string(3),
            status: status,
            defaultDateStart: row.double(5).map { Date(timeIntervalSince1970: $0) },
            defaultDateEnd: row.double(6).map { Date(timeIntervalSince1970: $0) },
            defaultScopeJSON: scopeJSON,
            createdAt: Date(timeIntervalSince1970: createdRaw),
            updatedAt: Date(timeIntervalSince1970: updatedRaw),
            archivedAt: row.double(10).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
