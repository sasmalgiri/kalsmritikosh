//
//  GroupRepository.swift
//  Kalsmritikosh
//
//  X-2 — your own folders inside the archive (schema v147). Groups form a tree; a
//  document can be a member of several groups at once (a replicant: the same document in
//  many places, never a copy). Groups organise; they never change evidence.
//
//  Nothing is deleted: removing a document from a group stamps `removed_at` (adding it back
//  clears it); retiring a group stamps `retired_at` on it and its descendants, and restoring
//  brings the whole branch back with its members.
//

import Foundation

public nonisolated struct UserGroup: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let sortIndex: Int
    public let memberCount: Int
    public let retired: Bool
}

public enum GroupRepositoryError: Error, LocalizedError, Equatable {
    case emptyName
    case groupNotFound
    case nameTaken(String)
    case wouldCreateCycle
    case parentRetired
    case documentNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "A group needs a name."
        case .groupNotFound: return "That group no longer exists."
        case .nameTaken(let n): return "There is already a group called \u{201C}\(n)\u{201D} here."
        case .wouldCreateCycle: return "A group cannot be moved inside itself or one of its own groups."
        case .parentRetired: return "That group has been removed; restore it first."
        case .documentNotFound: return "That document is not in the archive."
        }
    }
}

public actor GroupRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Reading

    /// Every live group (or every group, retired included), parents before children, siblings
    /// in their sort order, with how many live members each has.
    public func all(includeRetired: Bool = false) async throws -> [UserGroup] {
        let rows = try await database.query("""
            SELECT g.id, g.name, g.parent_id, g.sort_index, g.retired_at IS NOT NULL,
                   (SELECT COUNT(*) FROM user_group_members m WHERE m.group_id = g.id AND m.removed_at IS NULL)
            FROM user_groups g \(includeRetired ? "" : "WHERE g.retired_at IS NULL")
            ORDER BY g.sort_index, g.name COLLATE NOCASE;
            """, [])
        let flat = rows.compactMap { r -> UserGroup? in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return UserGroup(id: id, name: name, parentID: r.uuid(2), sortIndex: Int(r.int(3) ?? 0),
                             memberCount: Int(r.int(5) ?? 0), retired: (r.int(4) ?? 0) != 0)
        }
        return Self.treeOrder(flat)
    }

    /// Depth-first order: each parent followed by its children (in sort order). Groups whose
    /// parent is missing from the list are treated as top level, so nothing disappears.
    static func treeOrder(_ groups: [UserGroup]) -> [UserGroup] {
        let ids = Set(groups.map(\.id))
        var children: [UUID?: [UserGroup]] = [:]
        for g in groups {
            let parent = g.parentID.flatMap { ids.contains($0) ? $0 : nil }
            children[parent, default: []].append(g)
        }
        var out: [UserGroup] = []
        var seen = Set<UUID>()
        func visit(_ parent: UUID?) {
            for g in children[parent] ?? [] where seen.insert(g.id).inserted {
                out.append(g)
                visit(g.id)
            }
        }
        visit(nil)
        return out
    }

    /// Ids of a group and every group beneath it.
    public func branch(_ groupID: UUID) async throws -> [UUID] {
        let rows = try await database.query("""
            WITH RECURSIVE b(id) AS (
                SELECT ? UNION SELECT g.id FROM user_groups g JOIN b ON g.parent_id = b.id
            ) SELECT id FROM b;
            """, [.uuid(groupID)])
        return rows.compactMap { $0.uuid(0) }
    }

    /// Live members of a group, optionally including every group beneath it (each document
    /// once, however many of those groups hold it).
    public func members(of groupID: UUID, includingSubgroups: Bool = false) async throws -> [UUID] {
        let groups = includingSubgroups ? try await branch(groupID) : [groupID]
        guard !groups.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: groups.count).joined(separator: ",")
        let rows = try await database.query("""
            SELECT DISTINCT m.object_id FROM user_group_members m JOIN user_groups g ON g.id = m.group_id
            WHERE m.group_id IN (\(marks)) AND m.removed_at IS NULL AND g.retired_at IS NULL
            ORDER BY m.added_at, m.object_id;
            """, groups.map { .uuid($0) })
        return rows.compactMap { $0.uuid(0) }
    }

    /// The live groups a document is in (more than one ⇒ it is a replicant).
    public func groups(containing objectID: UUID) async throws -> [UserGroup] {
        let rows = try await database.query("""
            SELECT g.id, g.name, g.parent_id, g.sort_index
            FROM user_group_members m JOIN user_groups g ON g.id = m.group_id
            WHERE m.object_id = ? AND m.removed_at IS NULL AND g.retired_at IS NULL
            ORDER BY g.name COLLATE NOCASE;
            """, [.uuid(objectID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return UserGroup(id: id, name: name, parentID: r.uuid(2), sortIndex: Int(r.int(3) ?? 0),
                             memberCount: 0, retired: false)
        }
    }

    /// Documents in no live group, newest first.
    public func unfiled(limit: Int = 500) async throws -> [UUID] {
        let rows = try await database.query("""
            SELECT ko.id FROM knowledge_objects ko
            WHERE NOT EXISTS (
                SELECT 1 FROM user_group_members m JOIN user_groups g ON g.id = m.group_id
                WHERE m.object_id = ko.id AND m.removed_at IS NULL AND g.retired_at IS NULL)
            ORDER BY ko.created_at DESC, ko.id LIMIT ?;
            """, [.integer(Int64(max(1, limit)))])
        return rows.compactMap { $0.uuid(0) }
    }

    /// The live group with this name (case-insensitive) anywhere in the tree, for `group:`.
    public func groups(named raw: String) async throws -> [UUID] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try await database.query(
            "SELECT id FROM user_groups WHERE name = ? COLLATE NOCASE AND retired_at IS NULL ORDER BY id;",
            [.text(name)])
        return rows.compactMap { $0.uuid(0) }
    }

    // MARK: - Changing the tree

    /// Create a group (top level when `parent` is nil). Names are unique among live siblings.
    @discardableResult
    public func create(name raw: String, parent: UUID? = nil, sourcePath: String? = nil) async throws -> UUID {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GroupRepositoryError.emptyName }
        let id = UUID()
        try await database.withSavepoint("group_create") { db in
            if let parent { try Self.requireLive(parent, db) }
            try Self.requireFreeName(name, parent: parent, except: nil, db)
            let next = Int(try db.query("""
                SELECT COALESCE(MAX(sort_index), -1) + 1 FROM user_groups
                WHERE COALESCE(parent_id, '') = COALESCE(?, '') AND retired_at IS NULL;
                """, [parent.map { .uuid($0) } ?? .null]).first?.int(0) ?? 0)
            try db.exec("""
                INSERT INTO user_groups (id, name, parent_id, sort_index, created_at, source_path)
                VALUES (?, ?, ?, ?, ?, ?);
                """, [.uuid(id), .text(name), parent.map { .uuid($0) } ?? .null, .integer(Int64(next)),
                      .date(Date()), sourcePath.map { .text($0) } ?? .null])
        }
        return id
    }

    public func rename(_ groupID: UUID, to raw: String) async throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GroupRepositoryError.emptyName }
        try await database.withSavepoint("group_rename") { db in
            let parent = try Self.requireLive(groupID, db)
            try Self.requireFreeName(name, parent: parent, except: groupID, db)
            try db.exec("UPDATE user_groups SET name = ? WHERE id = ?;", [.text(name), .uuid(groupID)])
        }
    }

    /// Move a group under another (nil = top level). Refuses to move a group into itself or
    /// below one of its own descendants.
    public func move(_ groupID: UUID, under newParent: UUID?) async throws {
        try await database.withSavepoint("group_move") { db in
            try Self.requireLive(groupID, db)
            if let newParent {
                try Self.requireLive(newParent, db)
                let below = try db.query("""
                    WITH RECURSIVE b(id) AS (
                        SELECT ? UNION SELECT g.id FROM user_groups g JOIN b ON g.parent_id = b.id
                    ) SELECT 1 FROM b WHERE id = ? LIMIT 1;
                    """, [.uuid(groupID), .uuid(newParent)])
                if !below.isEmpty { throw GroupRepositoryError.wouldCreateCycle }
            }
            let name = try db.query("SELECT name FROM user_groups WHERE id = ?;", [.uuid(groupID)]).first?.string(0) ?? ""
            try Self.requireFreeName(name, parent: newParent, except: groupID, db)
            try db.exec("UPDATE user_groups SET parent_id = ? WHERE id = ?;",
                        [newParent.map { .uuid($0) } ?? .null, .uuid(groupID)])
        }
    }

    /// Put the given siblings in this order (others keep their relative order after them).
    public func reorder(_ orderedIDs: [UUID]) async throws {
        try await database.withSavepoint("group_reorder") { db in
            for (i, id) in orderedIDs.enumerated() {
                try db.exec("UPDATE user_groups SET sort_index = ? WHERE id = ? AND retired_at IS NULL;",
                            [.integer(Int64(i)), .uuid(id)])
            }
        }
    }

    /// Retire a group and everything beneath it. Members are kept and come back on restore.
    public func retire(_ groupID: UUID) async throws {
        let ids = try await branch(groupID)
        let now = Date()
        try await database.withSavepoint("group_retire") { db in
            try Self.requireLive(groupID, db)
            for id in ids {
                try db.exec("UPDATE user_groups SET retired_at = ? WHERE id = ? AND retired_at IS NULL;",
                            [.date(now), .uuid(id)])
            }
        }
    }

    /// Restore a retired group and the branch retired with it. Refuses when the parent is
    /// itself retired, or when a live sibling has taken the name meanwhile.
    public func restore(_ groupID: UUID) async throws {
        try await database.withSavepoint("group_restore") { db in
            guard let row = try db.query("SELECT name, parent_id, retired_at FROM user_groups WHERE id = ?;",
                                         [.uuid(groupID)]).first else { throw GroupRepositoryError.groupNotFound }
            guard let retiredAt = row.double(2) else { return }
            let parent = row.uuid(1)
            if let parent {
                let live = try db.query("SELECT 1 FROM user_groups WHERE id = ? AND retired_at IS NULL;", [.uuid(parent)])
                if live.isEmpty { throw GroupRepositoryError.parentRetired }
            }
            try Self.requireFreeName(row.string(0) ?? "", parent: parent, except: groupID, db)
            // Bring back the branch that was retired together (same stamp), not groups the
            // person had retired separately before.
            try db.exec("""
                WITH RECURSIVE b(id) AS (
                    SELECT ? UNION SELECT g.id FROM user_groups g JOIN b ON g.parent_id = b.id
                ) UPDATE user_groups SET retired_at = NULL WHERE id IN (SELECT id FROM b) AND retired_at = ?;
                """, [.uuid(groupID), .real(retiredAt)])
        }
    }

    // MARK: - Membership

    /// Put a document in a group (adding it back after a removal restores the membership).
    public func add(_ objectID: UUID, to groupID: UUID) async throws {
        try await database.withSavepoint("group_add") { db in
            try Self.requireLive(groupID, db)
            guard try !db.query("SELECT 1 FROM knowledge_objects WHERE id = ?;", [.uuid(objectID)]).isEmpty
            else { throw GroupRepositoryError.documentNotFound }
            try db.exec("""
                INSERT INTO user_group_members (group_id, object_id, added_at) VALUES (?, ?, ?)
                ON CONFLICT (group_id, object_id) DO UPDATE SET removed_at = NULL;
                """, [.uuid(groupID), .uuid(objectID), .date(Date())])
        }
    }

    /// Take a document out of a group; it stays in its other groups and in the archive.
    public func remove(_ objectID: UUID, from groupID: UUID) async throws {
        try await database.exec("""
            UPDATE user_group_members SET removed_at = ?
            WHERE group_id = ? AND object_id = ? AND removed_at IS NULL;
            """, [.date(Date()), .uuid(groupID), .uuid(objectID)])
    }

    /// Move a document from one group to another (a move, not a replicant).
    public func moveDocument(_ objectID: UUID, from source: UUID, to target: UUID) async throws {
        guard source != target else { return }
        try await add(objectID, to: target)
        try await remove(objectID, from: source)
    }

    // MARK: - Mirror a folder tree

    public struct MirrorResult: Sendable, Equatable {
        public var groupsCreated = 0
        public var membershipsAdded = 0
        public var skippedRetired = 0
    }

    /// The folder path of `file` relative to `root` ([] when the file sits at the top, nil when
    /// it is not under `root`).
    nonisolated static func relativeFolders(of file: String, under root: String) -> [String]? {
        let rootParts = root.split(separator: "/").map(String.init)
        let fileParts = file.split(separator: "/").map(String.init)
        guard fileParts.count > rootParts.count, Array(fileParts.prefix(rootParts.count)) == rootParts else { return nil }
        return Array(fileParts.dropFirst(rootParts.count).dropLast())
    }

    /// Build groups that follow a source folder's structure, under one top group named after
    /// the folder, and put each document in the group of its folder. Files on disk are never
    /// touched. Re-running adds only what is new: groups are found again by the folder path
    /// they came from (so a group the person renamed is still reused), a group the person
    /// removed is not brought back, and no membership is ever taken away.
    @discardableResult
    public func mirror(rootName: String, rootPath: String, documents: [(objectID: UUID, path: String)]) async throws -> MirrorResult {
        var result = MirrorResult()
        var cache: [String: UUID?] = [:]   // folder path → live group id, nil = retired (skip)

        func groupFor(_ folders: [String]) async throws -> UUID? {
            let key = ([rootPath] + folders).joined(separator: "/")
            if let hit = cache[key] { return hit }
            let parent: UUID? = folders.isEmpty ? nil : try await groupFor(Array(folders.dropLast()))
            if !folders.isEmpty && parent == nil { cache[key] = .some(nil); return nil }
            let rows = try await database.query(
                "SELECT id, retired_at FROM user_groups WHERE source_path = ? ORDER BY created_at LIMIT 1;", [.text(key)])
            if let row = rows.first, let id = row.uuid(0) {
                let live: UUID? = row.double(1) == nil ? id : nil
                if live == nil { result.skippedRetired += 1 }
                cache[key] = .some(live)
                return live
            }
            let name = folders.last ?? rootName
            var candidate = name, n = 2
            while true {
                do {
                    let id = try await create(name: candidate, parent: parent, sourcePath: key)
                    result.groupsCreated += 1
                    cache[key] = .some(id)
                    return id
                } catch GroupRepositoryError.nameTaken {
                    candidate = "\(name) \(n)"; n += 1
                }
            }
        }

        for doc in documents {
            guard let folders = Self.relativeFolders(of: doc.path, under: rootPath),
                  let group = try await groupFor(folders) else { continue }
            let already = try await database.query("""
                SELECT 1 FROM user_group_members WHERE group_id = ? AND object_id = ?;
                """, [.uuid(group), .uuid(doc.objectID)])
            guard already.isEmpty else { continue }   // never re-add one the person took out
            try await add(doc.objectID, to: group)
            result.membershipsAdded += 1
        }
        return result
    }

    // MARK: - Helpers

    /// The group's parent; throws when the group is missing or retired.
    @discardableResult
    private static func requireLive(_ id: UUID, _ db: isolated Database) throws -> UUID? {
        guard let row = try db.query("SELECT parent_id, retired_at FROM user_groups WHERE id = ?;", [.uuid(id)]).first
        else { throw GroupRepositoryError.groupNotFound }
        if row.double(1) != nil { throw GroupRepositoryError.parentRetired }
        return row.uuid(0)
    }

    private static func requireFreeName(_ name: String, parent: UUID?, except: UUID?, _ db: isolated Database) throws {
        let rows = try db.query("""
            SELECT id FROM user_groups
            WHERE COALESCE(parent_id, '') = COALESCE(?, '') AND name = ? COLLATE NOCASE AND retired_at IS NULL;
            """, [parent.map { .uuid($0) } ?? .null, .text(name)])
        if rows.contains(where: { $0.uuid(0) != except }) { throw GroupRepositoryError.nameTaken(name) }
    }
}
