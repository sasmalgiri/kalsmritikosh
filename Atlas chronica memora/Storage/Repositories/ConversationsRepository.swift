//
//  ConversationsRepository.swift
//  Atlas chronica memora
//
//  Persists Ask transcripts. Each conversation has an ordered list of
//  turns (user prompts + assistant answers). Lets the brain reason
//  with prior-question context and lets users scroll back through
//  past questions.
//

import Foundation

public struct Conversation: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let title: String?

    public init(id: UUID = UUID(), startedAt: Date = .init(), title: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
    }
}

public struct ConversationTurn: Identifiable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable {
        case user, assistant
    }

    public let id: UUID
    public let conversationID: UUID
    public let ordinal: Int
    public let role: Role
    public let body: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        ordinal: Int,
        role: Role,
        body: String,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.ordinal = ordinal
        self.role = role
        self.body = body
        self.createdAt = createdAt
    }
}

public actor ConversationsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Conversations

    public func create(title: String? = nil) async throws -> Conversation {
        let conv = Conversation(title: title)
        try await database.exec("""
        INSERT INTO conversations (id, started_at, title) VALUES (?, ?, ?);
        """, [
            .uuid(conv.id),
            .date(conv.startedAt),
            .optionalText(conv.title)
        ])
        return conv
    }

    public func updateTitle(_ title: String, for id: UUID) async throws {
        try await database.exec(
            "UPDATE conversations SET title = ? WHERE id = ?;",
            [.text(title), .uuid(id)]
        )
    }

    public func delete(_ id: UUID) async throws {
        try await database.exec(
            "DELETE FROM conversations WHERE id = ?;",
            [.uuid(id)]
        )
    }

    public func recent(limit: Int = 50) async throws -> [Conversation] {
        let rows = try await database.query(
            "SELECT id, started_at, title FROM conversations ORDER BY started_at DESC LIMIT ?;",
            [.integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let id = row.uuid(0), let started = row.date(1) else { return nil }
            return Conversation(id: id, startedAt: started, title: row.string(2))
        }
    }

    // MARK: - Turns

    public func appendTurn(_ turn: ConversationTurn) async throws {
        try await database.exec("""
        INSERT INTO conversation_turns
            (id, conversation_id, ordinal, role, body, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [
            .uuid(turn.id),
            .uuid(turn.conversationID),
            .integer(Int64(turn.ordinal)),
            .text(turn.role.rawValue),
            .text(turn.body),
            .date(turn.createdAt)
        ])
    }

    public func turns(for conversationID: UUID) async throws -> [ConversationTurn] {
        let rows = try await database.query("""
        SELECT id, conversation_id, ordinal, role, body, created_at
        FROM conversation_turns
        WHERE conversation_id = ?
        ORDER BY ordinal ASC;
        """, [.uuid(conversationID)])
        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let cid = row.uuid(1),
                let ordinal = row.int(2),
                let roleRaw = row.string(3),
                let role = ConversationTurn.Role(rawValue: roleRaw),
                let body = row.string(4),
                let created = row.date(5)
            else { return nil }
            return ConversationTurn(
                id: id,
                conversationID: cid,
                ordinal: Int(ordinal),
                role: role,
                body: body,
                createdAt: created
            )
        }
    }

    public func nextOrdinal(for conversationID: UUID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COALESCE(MAX(ordinal), -1) FROM conversation_turns WHERE conversation_id = ?;",
            [.uuid(conversationID)]
        )
        return Int((rows.first?.int(0) ?? -1) + 1)
    }
}
