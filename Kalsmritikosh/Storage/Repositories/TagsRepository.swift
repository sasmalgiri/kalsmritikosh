//
//  TagsRepository.swift
//  Kalsmritikosh
//
//  W1-4 — the user's own tags (schema v142). Tags organise; they never change
//  evidence status. Nothing is deleted: untag stamps `removed_at`, re-tag clears
//  it, merge re-points every link and retires the old tag.
//

import Foundation

public nonisolated struct UserTag: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let color: String?
    public let count: Int
}

public nonisolated enum TagSubjectKind: String, Sendable, CaseIterable {
    case object, fact, entity, event, chunk
}

public enum TagsRepositoryError: Error, LocalizedError {
    case emptyName, tagNotFound
    public var errorDescription: String? {
        switch self {
        case .emptyName:   return "A tag needs a name."
        case .tagNotFound: return "That tag no longer exists."
        }
    }
}

public actor TagsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Live tags with how many subjects carry each.
    public func allTags() async throws -> [UserTag] {
        let rows = try await database.query("""
            SELECT t.id, t.name, t.color,
                   (SELECT COUNT(*) FROM user_tag_links l WHERE l.tag_id = t.id AND l.removed_at IS NULL)
            FROM user_tags t WHERE t.retired_at IS NULL ORDER BY t.name COLLATE NOCASE;
            """, [])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return UserTag(id: id, name: name, color: r.string(2), count: Int(r.int(3) ?? 0))
        }
    }

    /// The live tag with this name, created when missing.
    @discardableResult
    public func tag(named raw: String, color: String? = nil) async throws -> UUID {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagsRepositoryError.emptyName }
        let newID = UUID()
        let now = Date()
        return try await database.withSavepoint("tag_named") { db in
            if let existing = try db.query(
                "SELECT id FROM user_tags WHERE name = ? COLLATE NOCASE AND retired_at IS NULL LIMIT 1;",
                [.text(name)]).first?.uuid(0) {
                return existing
            }
            try db.exec("INSERT INTO user_tags (id, name, color, created_at) VALUES (?, ?, ?, ?);",
                        [.uuid(newID), .text(name), color.map { .text($0) } ?? .null, .date(now)])
            return newID
        }
    }

    /// Attach a tag (re-attaching a removed link restores it).
    public func attach(tagID: UUID, to kind: TagSubjectKind, _ subjectID: UUID) async throws {
        try await database.exec("""
            INSERT INTO user_tag_links (tag_id, subject_kind, subject_id, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (tag_id, subject_kind, subject_id) DO UPDATE SET removed_at = NULL;
            """, [.uuid(tagID), .text(kind.rawValue), .uuid(subjectID), .date(Date())])
    }

    /// Detach without deleting: the link is stamped removed.
    public func detach(tagID: UUID, from kind: TagSubjectKind, _ subjectID: UUID) async throws {
        try await database.exec("""
            UPDATE user_tag_links SET removed_at = ?
            WHERE tag_id = ? AND subject_kind = ? AND subject_id = ? AND removed_at IS NULL;
            """, [.date(Date()), .uuid(tagID), .text(kind.rawValue), .uuid(subjectID)])
    }

    public func tags(for kind: TagSubjectKind, _ subjectID: UUID) async throws -> [UserTag] {
        let rows = try await database.query("""
            SELECT t.id, t.name, t.color FROM user_tag_links l JOIN user_tags t ON t.id = l.tag_id
            WHERE l.subject_kind = ? AND l.subject_id = ? AND l.removed_at IS NULL AND t.retired_at IS NULL
            ORDER BY t.name COLLATE NOCASE;
            """, [.text(kind.rawValue), .uuid(subjectID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return UserTag(id: id, name: name, color: r.string(2), count: 0)
        }
    }

    /// Subjects of `kind` carrying the live tag `name`.
    public func subjects(taggedWith name: String, kind: TagSubjectKind) async throws -> [UUID] {
        let rows = try await database.query("""
            SELECT l.subject_id FROM user_tag_links l JOIN user_tags t ON t.id = l.tag_id
            WHERE t.name = ? COLLATE NOCASE AND t.retired_at IS NULL AND l.removed_at IS NULL AND l.subject_kind = ?;
            """, [.text(name), .text(kind.rawValue)])
        return rows.compactMap { $0.uuid(0) }
    }

    public func rename(tagID: UUID, to raw: String) async throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagsRepositoryError.emptyName }
        try await database.exec("UPDATE user_tags SET name = ? WHERE id = ? AND retired_at IS NULL;",
                                [.text(name), .uuid(tagID)])
    }

    /// Fold `source` into `target`: every live link moves, `source` is retired (kept, not deleted).
    public func merge(_ source: UUID, into target: UUID) async throws {
        guard source != target else { return }
        let now = Date()
        try await database.withSavepoint("tag_merge") { db in
            guard try db.query("SELECT 1 FROM user_tags WHERE id = ? AND retired_at IS NULL;", [.uuid(target)]).first != nil
            else { throw TagsRepositoryError.tagNotFound }
            try db.exec("""
                INSERT INTO user_tag_links (tag_id, subject_kind, subject_id, created_at)
                SELECT ?, subject_kind, subject_id, created_at FROM user_tag_links
                WHERE tag_id = ? AND removed_at IS NULL
                ON CONFLICT (tag_id, subject_kind, subject_id) DO UPDATE SET removed_at = NULL;
                """, [.uuid(target), .uuid(source)])
            try db.exec("UPDATE user_tag_links SET removed_at = ? WHERE tag_id = ? AND removed_at IS NULL;",
                        [.date(now), .uuid(source)])
            try db.exec("UPDATE user_tags SET retired_at = ?, merged_into = ? WHERE id = ?;",
                        [.date(now), .uuid(target), .uuid(source)])
        }
    }
}
