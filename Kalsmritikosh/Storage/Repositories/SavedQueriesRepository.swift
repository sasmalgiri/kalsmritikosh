//
//  SavedQueriesRepository.swift
//  Kalsmritikosh
//
//  Phase J.7 — Vol 28 §Core Workspace. Lightweight question
//  bookmarks. The AskView's "save question" button appends a row;
//  a future Saved Queries surface lists + re-runs them.
//
//  No result snapshot — re-running a saved query re-walks the live
//  ledger. On a continuously ingesting personal archive that's the
//  right semantic; yesterday's question accumulates new evidence
//  every day.
//

import Foundation

public struct SavedQuery: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public let id: ID
    public let question: String
    public let title: String?
    public let notes: String?
    /// Optional QueryCategory rawValue. Lets a future UI filter
    /// by "show me my saved comparison questions". Nil = not
    /// classified at save time.
    public let category: String?
    public let createdAt: Date
    public let lastRunAt: Date?

    public nonisolated init(
        id: ID = UUID(),
        question: String,
        title: String? = nil,
        notes: String? = nil,
        category: String? = nil,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.question = question
        self.title = title
        self.notes = notes
        self.category = category
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }
}

public actor SavedQueriesRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ saved: SavedQuery) async throws {
        try await database.exec("""
        INSERT INTO saved_queries
            (id, question, title, notes, category, created_at, last_run_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(saved.id),
            .text(saved.question),
            saved.title.map { .text($0) } ?? .null,
            saved.notes.map { .text($0) } ?? .null,
            saved.category.map { .text($0) } ?? .null,
            .real(saved.createdAt.timeIntervalSince1970),
            saved.lastRunAt.map { .real($0.timeIntervalSince1970) } ?? .null
        ])
    }

    public func touchLastRun(id: UUID, at when: Date = Date()) async throws {
        try await database.exec(
            "UPDATE saved_queries SET last_run_at = ? WHERE id = ?;",
            [.real(when.timeIntervalSince1970), .uuid(id)]
        )
    }

    public func delete(_ id: UUID) async throws {
        try await database.exec(
            "DELETE FROM saved_queries WHERE id = ?;",
            [.uuid(id)]
        )
    }

    public func recent(limit: Int = 100) async throws -> [SavedQuery] {
        let rows = try await database.query("""
        SELECT id, question, title, notes, category, created_at, last_run_at
        FROM saved_queries
        ORDER BY created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM saved_queries;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> SavedQuery? {
        guard
            let id = row.uuid(0),
            let question = row.string(1),
            let createdAtRaw = row.double(5)
        else { return nil }
        let lastRun = row.double(6).map { Date(timeIntervalSince1970: $0) }
        return SavedQuery(
            id: id,
            question: question,
            title: row.string(2),
            notes: row.string(3),
            category: row.string(4),
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            lastRunAt: lastRun
        )
    }
}
