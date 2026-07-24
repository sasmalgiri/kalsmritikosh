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

    /// Derive + persist subject membership for one workspace. Returns the number of member
    /// subjects. Idempotent (addEntity ignores duplicates).
    @discardableResult
    public func deriveMembership(for workspaceID: Workspace.ID, at when: Date = Date()) async throws -> Int {
        let fileIDs = try await workspaces.sourceIDs(in: workspaceID)
        guard !fileIDs.isEmpty else { return 0 }
        let entityIDs = try await entities(inFiles: fileIDs)
        for e in entityIDs { try await workspaces.addEntity(e, to: workspaceID, at: when) }
        return entityIDs.count
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

    /// The entities anchored (via their source knowledge object) to any of the given files.
    /// Chunked ≤500 file ids so a large workspace never exceeds SQLite's bind-variable limit.
    private func entities(inFiles fileIDs: [UUID]) async throws -> [Entity.ID] {
        let unique = Array(Set(fileIDs))
        var out: Set<Entity.ID> = []
        for chunk in stride(from: 0, to: unique.count, by: 500).map({ Array(unique[$0..<min($0 + 500, unique.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("""
            SELECT DISTINCT e.id
            FROM entities e
            JOIN knowledge_objects ko ON ko.id = e.source_object_id
            WHERE ko.file_id IN (\(placeholders));
            """, chunk.map { .uuid($0) })
            for r in rows { if let id = r.uuid(0) { out.insert(id) } }
        }
        return out.sorted { $0.uuidString < $1.uuidString }
    }
}
