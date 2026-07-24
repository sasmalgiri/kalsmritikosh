//
//  WorkspaceMembershipDeriver.swift
//  Kalsmritikosh
//
//  PA-PROD — derives workspace SUBJECT membership from PERSISTED IDENTITY, never from free
//  text. A workspace holds source FILES; each entity is anchored to the knowledge object it
//  was extracted from, which belongs to a file. So a workspace's subjects are exactly the
//  entities whose source object's file is one of the workspace's source files:
//
//      workspace_sources.file_id  →  knowledge_objects.file_id  →  entities.source_object_id
//
//  Membership is written through the existing membership layer (WorkspaceRepository.addEntity,
//  idempotent ON CONFLICT DO NOTHING). No workspace field is ever added to a Claim.
//

import Foundation

public actor WorkspaceMembershipDeriver {
    private let database: Database
    private let workspaces: WorkspaceRepository

    public init(database: Database, workspaces: WorkspaceRepository) {
        self.database = database
        self.workspaces = workspaces
    }

    /// RECONCILE the derived subject membership for one workspace: compute the expected set
    /// from current sources and replace the derived set (add missing, drop obsolete) inside one
    /// savepoint — manually-curated members are never touched. Returns the derived-member count.
    /// Idempotent. A workspace with no sources ends up with an empty derived set (obsolete
    /// derived rows removed).
    @discardableResult
    public func deriveMembership(for workspaceID: Workspace.ID, at when: Date = Date()) async throws -> Int {
        let fileIDs = try await workspaces.sourceIDs(in: workspaceID)
        let expected = fileIDs.isEmpty ? [] : try await entities(inFiles: fileIDs)
        try await workspaces.replaceDerivedEntities(Set(expected), in: workspaceID, at: when)
        return expected.count
    }

    /// Derive membership for every active workspace. Returns total memberships added.
    @discardableResult
    public func deriveAll(at when: Date = Date()) async throws -> Int {
        var total = 0
        for ws in try await workspaces.all(includeArchived: false) {
            total += try await deriveMembership(for: ws.id, at: when)
        }
        return total
    }

    /// The entities that OCCUR in any of the given files. Membership follows every occurrence
    /// via `entity_mentions` (a canonical entity mentioned in file B is a member of a workspace
    /// containing file B, even if it first originated in file A). `entities.source_object_id`
    /// is used ONLY as a fallback for legacy entities that have no mention row at all. Chunked
    /// ≤500 file ids so a large workspace never exceeds SQLite's bind-variable limit.
    private func entities(inFiles fileIDs: [UUID]) async throws -> [Entity.ID] {
        let unique = Array(Set(fileIDs))
        var out: Set<Entity.ID> = []
        for chunk in stride(from: 0, to: unique.count, by: 500).map({ Array(unique[$0..<min($0 + 500, unique.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let binds = chunk.map { SQLValue.uuid($0) }
            // Primary: every occurrence via entity_mentions.
            let mentionRows = try await database.query("""
            SELECT DISTINCT em.entity_id
            FROM entity_mentions em
            JOIN knowledge_objects ko ON ko.id = em.source_object_id
            WHERE ko.file_id IN (\(placeholders));
            """, binds)
            for r in mentionRows { if let id = r.uuid(0) { out.insert(id) } }
            // Fallback: entities with NO mention row at all, anchored by source_object_id.
            let fallbackRows = try await database.query("""
            SELECT DISTINCT e.id
            FROM entities e
            JOIN knowledge_objects ko ON ko.id = e.source_object_id
            WHERE ko.file_id IN (\(placeholders))
              AND NOT EXISTS (SELECT 1 FROM entity_mentions em WHERE em.entity_id = e.id);
            """, binds)
            for r in fallbackRows { if let id = r.uuid(0) { out.insert(id) } }
        }
        return out.sorted { $0.uuidString < $1.uuidString }
    }
}
