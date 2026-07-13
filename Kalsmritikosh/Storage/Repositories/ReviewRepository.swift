//
//  ReviewRepository.swift
//  Kalsmritikosh
//
//  Persona features Epic 1 (F2). Tags, the append-only review-decision
//  ledger, and saved views. review_decisions is NEVER mutated in place:
//  every state change / tag application / note is a new row carrying
//  prior→new values (§7.4 "history shows old and new values"), and an undo
//  is a reversing row (`reversalOf`). No review action ever changes source
//  evidence.
//

import Foundation

public actor ReviewRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Tags

    public func createTag(_ tag: ReviewTag) async throws {
        try await database.exec("""
        INSERT INTO review_tags (id, workspace_id, name, color, kind, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [
            .uuid(tag.id),
            tag.workspaceID.map { .uuid($0) } ?? .null,
            .text(tag.name),
            tag.color.map { .text($0) } ?? .null,
            .text(tag.kind),
            .real(tag.createdAt.timeIntervalSince1970)
        ])
    }

    /// Tags visible in a workspace: its own + global (workspace_id IS NULL).
    public func tags(inWorkspace workspaceID: Workspace.ID?) async throws -> [ReviewTag] {
        let rows: [SQLRow]
        if let workspaceID {
            rows = try await database.query("""
            SELECT id, workspace_id, name, color, kind, created_at
            FROM review_tags
            WHERE workspace_id = ? OR workspace_id IS NULL
            ORDER BY name ASC;
            """, [.uuid(workspaceID)])
        } else {
            rows = try await database.query("""
            SELECT id, workspace_id, name, color, kind, created_at
            FROM review_tags WHERE workspace_id IS NULL ORDER BY name ASC;
            """)
        }
        return rows.compactMap(decodeTag)
    }

    public func deleteTag(_ id: ReviewTag.ID) async throws {
        try await database.exec("DELETE FROM review_tags WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - Decisions (append-only)

    public func append(_ decision: ReviewDecision) async throws {
        try await database.exec("""
        INSERT INTO review_decisions
            (id, workspace_id, target_kind, target_id, dimension, decision,
             tag_id, note, prior_value, reviewer, reversal_of, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(decision.id),
            decision.workspaceID.map { .uuid($0) } ?? .null,
            .text(decision.targetKind.rawValue),
            .text(decision.targetID),
            .text(decision.dimension.rawValue),
            decision.decision.map { .text($0) } ?? .null,
            decision.tagID.map { .uuid($0) } ?? .null,
            decision.note.map { .text($0) } ?? .null,
            decision.priorValue.map { .text($0) } ?? .null,
            .text(decision.reviewer),
            decision.reversalOf.map { .uuid($0) } ?? .null,
            .real(decision.createdAt.timeIntervalSince1970)
        ])
    }

    /// Full audit history for one target, oldest → newest.
    public func history(forTarget kind: ReviewTarget, id targetID: String) async throws -> [ReviewDecision] {
        let rows = try await database.query("""
        SELECT id, workspace_id, target_kind, target_id, dimension, decision,
               tag_id, note, prior_value, reviewer, reversal_of, created_at
        FROM review_decisions
        WHERE target_kind = ? AND target_id = ?
        ORDER BY created_at ASC;
        """, [.text(kind.rawValue), .text(targetID)])
        return rows.compactMap(decodeDecision)
    }

    /// The current review state for a target: the latest `.reviewState`
    /// decision that has NOT itself been reversed by a later row. Returns nil
    /// if the target was never reviewed (→ treat as `.unreviewed`).
    public func currentState(forTarget kind: ReviewTarget, id targetID: String) async throws -> ReviewState? {
        let all = try await history(forTarget: kind, id: targetID)
        let reversedIDs = Set(all.compactMap(\.reversalOf))
        let latest = all
            .filter { $0.dimension == .reviewState && !reversedIDs.contains($0.id) }
            .last
        guard let raw = latest?.decision else { return nil }
        return ReviewState(rawValue: raw)
    }

    /// Currently-applied tag IDs for a target: fold the append-only add/remove
    /// stream (ignoring reversed rows) into the live set.
    public func currentTagIDs(forTarget kind: ReviewTarget, id targetID: String) async throws -> [ReviewTag.ID] {
        let all = try await history(forTarget: kind, id: targetID)
        let reversedIDs = Set(all.compactMap(\.reversalOf))
        var live: [ReviewTag.ID] = []
        for d in all where d.dimension == .tag && !reversedIDs.contains(d.id) {
            guard let tagID = d.tagID else { continue }
            if d.decision == "remove" {
                live.removeAll { $0 == tagID }
            } else { // "add" (default)
                if !live.contains(tagID) { live.append(tagID) }
            }
        }
        return live
    }

    /// Targets in a workspace currently carrying a given review state. Used by
    /// saved views (e.g. "all disputed findings"). Folds the append-only
    /// stream per target so only the live state counts.
    public func targets(inWorkspace workspaceID: Workspace.ID, withState state: ReviewState) async throws -> [(kind: ReviewTarget, id: String)] {
        let rows = try await database.query("""
        SELECT target_kind, target_id, dimension, decision, id, reversal_of, created_at
        FROM review_decisions
        WHERE workspace_id = ? AND dimension = 'reviewState'
        ORDER BY created_at ASC;
        """, [.uuid(workspaceID)])
        var reversed = Set<String>()
        for r in rows { if let rev = r.string(5) { reversed.insert(rev) } }
        var currentByTarget: [String: (kind: ReviewTarget, id: String, state: String)] = [:]
        for r in rows {
            guard
                let kindRaw = r.string(0), let kind = ReviewTarget(rawValue: kindRaw),
                let targetID = r.string(1), let rowID = r.string(4),
                let decision = r.string(3)
            else { continue }
            if reversed.contains(rowID) { continue }
            currentByTarget[targetID] = (kind, targetID, decision)
        }
        return currentByTarget.values
            .filter { $0.state == state.rawValue }
            .map { ($0.kind, $0.id) }
    }

    // MARK: - Saved views

    public func saveView(_ view: SavedView) async throws {
        try await database.exec("""
        INSERT INTO saved_views (id, workspace_id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at;
        """, [
            .uuid(view.id),
            view.workspaceID.map { .uuid($0) } ?? .null,
            .text(view.title),
            .real(view.createdAt.timeIntervalSince1970),
            .real(view.updatedAt.timeIntervalSince1970)
        ])
        // Filters are the definition of the view — replace them wholesale so a
        // re-save is deterministic (§7.4 "saved views reopen deterministically").
        try await database.exec("DELETE FROM saved_view_filters WHERE view_id = ?;", [.uuid(view.id)])
        for f in view.filters {
            try await database.exec("""
            INSERT INTO saved_view_filters (id, view_id, filter_key, filter_value)
            VALUES (?, ?, ?, ?);
            """, [.uuid(f.id), .uuid(view.id), .text(f.key), .text(f.value)])
        }
    }

    public func views(inWorkspace workspaceID: Workspace.ID?) async throws -> [SavedView] {
        let rows: [SQLRow]
        if let workspaceID {
            rows = try await database.query(
                "SELECT id, workspace_id, title, created_at, updated_at FROM saved_views WHERE workspace_id = ? ORDER BY updated_at DESC;",
                [.uuid(workspaceID)]
            )
        } else {
            rows = try await database.query(
                "SELECT id, workspace_id, title, created_at, updated_at FROM saved_views WHERE workspace_id IS NULL ORDER BY updated_at DESC;"
            )
        }
        var views: [SavedView] = []
        for row in rows {
            guard var view = decodeView(row) else { continue }
            view.filters = try await filters(forView: view.id)
            views.append(view)
        }
        return views
    }

    public func deleteView(_ id: SavedView.ID) async throws {
        try await database.exec("DELETE FROM saved_views WHERE id = ?;", [.uuid(id)])
    }

    private func filters(forView viewID: SavedView.ID) async throws -> [SavedViewFilter] {
        let rows = try await database.query(
            "SELECT id, filter_key, filter_value FROM saved_view_filters WHERE view_id = ?;",
            [.uuid(viewID)]
        )
        return rows.compactMap { row in
            guard let id = row.uuid(0), let key = row.string(1), let value = row.string(2) else { return nil }
            return SavedViewFilter(id: id, key: key, value: value)
        }
    }

    // MARK: - Decode

    private func decodeTag(_ row: SQLRow) -> ReviewTag? {
        guard let id = row.uuid(0), let name = row.string(2), let kind = row.string(4),
              let createdRaw = row.double(5) else { return nil }
        return ReviewTag(
            id: id,
            workspaceID: row.uuid(1),
            name: name,
            color: row.string(3),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdRaw)
        )
    }

    private func decodeDecision(_ row: SQLRow) -> ReviewDecision? {
        guard
            let id = row.uuid(0),
            let targetKindRaw = row.string(2), let targetKind = ReviewTarget(rawValue: targetKindRaw),
            let targetID = row.string(3),
            let dimensionRaw = row.string(4), let dimension = ReviewDimension(rawValue: dimensionRaw),
            let reviewer = row.string(9),
            let createdRaw = row.double(11)
        else { return nil }
        return ReviewDecision(
            id: id,
            workspaceID: row.uuid(1),
            targetKind: targetKind,
            targetID: targetID,
            dimension: dimension,
            decision: row.string(5),
            tagID: row.uuid(6),
            note: row.string(7),
            priorValue: row.string(8),
            reviewer: reviewer,
            reversalOf: row.uuid(10),
            createdAt: Date(timeIntervalSince1970: createdRaw)
        )
    }

    private func decodeView(_ row: SQLRow) -> SavedView? {
        guard let id = row.uuid(0), let title = row.string(2),
              let createdRaw = row.double(3), let updatedRaw = row.double(4) else { return nil }
        return SavedView(
            id: id,
            workspaceID: row.uuid(1),
            title: title,
            filters: [],
            createdAt: Date(timeIntervalSince1970: createdRaw),
            updatedAt: Date(timeIntervalSince1970: updatedRaw)
        )
    }
}
