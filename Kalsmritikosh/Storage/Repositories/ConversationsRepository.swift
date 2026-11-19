//
//  ConversationsRepository.swift
//  Kalsmritikosh
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
    /// v174 (LS24) — the case this conversation was asked in; nil for a library conversation (every
    /// conversation saved before v174 is one). Ask in a case sees only its own case's conversations.
    public let caseID: UUID?

    public nonisolated init(id: UUID = UUID(), startedAt: Date = .init(), title: String? = nil, caseID: UUID? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.caseID = caseID
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
    /// G2/Stage-3 — the durable answer this assistant turn was verified from.
    /// On reopen the citations / status / receipt are restored from this
    /// ledger row. nil for user turns and legacy turns (honest "not linked").
    public let answerLedgerID: UUID?

    public nonisolated init(
        id: UUID = UUID(),
        conversationID: UUID,
        ordinal: Int,
        role: Role,
        body: String,
        createdAt: Date = .init(),
        answerLedgerID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.ordinal = ordinal
        self.role = role
        self.body = body
        self.createdAt = createdAt
        self.answerLedgerID = answerLedgerID
    }
}

public actor ConversationsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Conversations

    /// `caseID` — the case Ask is open in (nil: the whole library).
    public func create(title: String? = nil, caseID: UUID? = nil) async throws -> Conversation {
        let conv = Conversation(title: title, caseID: caseID)
        try await database.exec("""
        INSERT INTO conversations (id, started_at, title, case_id) VALUES (?, ?, ?, ?);
        """, [
            .uuid(conv.id),
            .date(conv.startedAt),
            .optionalText(conv.title),
            caseID.map { .uuid($0) } ?? .null
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

    /// The most recent conversations of ONE scope (LS24): `caseID` nil lists the library conversations
    /// only (unbound, including every pre-v174 one); a case id lists only that case's conversations.
    public func recent(limit: Int = 50, caseID: UUID? = nil) async throws -> [Conversation] {
        let rows = try await database.query(
            "SELECT id, started_at, title, case_id FROM conversations WHERE case_id IS ? ORDER BY started_at DESC LIMIT ?;",
            [caseID.map { .uuid($0) } ?? .null, .integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let id = row.uuid(0), let started = row.date(1) else { return nil }
            return Conversation(id: id, startedAt: started, title: row.string(2), caseID: row.uuid(3))
        }
    }

    /// What Ask opens on (LS24): the most recent conversation of this scope with its turns, or a new
    /// conversation bound to the scope when there is none. Never a conversation of another case or of
    /// the library.
    public func resumeOrCreate(caseID: UUID?) async throws -> (Conversation, [ConversationTurn]) {
        if let recent = try await recent(limit: 1, caseID: caseID).first {
            return (recent, try await turns(for: recent.id))
        }
        return (try await create(caseID: caseID), [])
    }

    // MARK: - Turns

    public func appendTurn(_ turn: ConversationTurn) async throws {
        try await database.exec("""
        INSERT INTO conversation_turns
            (id, conversation_id, ordinal, role, body, created_at, answer_ledger_id)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(turn.id),
            .uuid(turn.conversationID),
            .integer(Int64(turn.ordinal)),
            .text(turn.role.rawValue),
            .text(turn.body),
            .date(turn.createdAt),
            .optionalText(turn.answerLedgerID?.uuidString)
        ])
    }

    /// G2/Stage-3 — bind a saved assistant turn to its durable answer once the
    /// ledger commit id is known (the answer is persisted after the turn body).
    public func linkAnswer(turnID: UUID, answerLedgerID: UUID) async throws {
        try await database.exec(
            "UPDATE conversation_turns SET answer_ledger_id = ? WHERE id = ?;",
            [.text(answerLedgerID.uuidString), .uuid(turnID)])
    }

    public func turns(for conversationID: UUID) async throws -> [ConversationTurn] {
        let rows = try await database.query("""
        SELECT id, conversation_id, ordinal, role, body, created_at, answer_ledger_id
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
                createdAt: created,
                answerLedgerID: row.string(6).flatMap(UUID.init(uuidString:))
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
