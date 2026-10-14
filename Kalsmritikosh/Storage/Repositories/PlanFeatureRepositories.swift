//
//  PlanFeatureRepositories.swift
//  Kalsmritikosh
//
//  Schema v144 repositories for the beat-DEVONthink plan: watchlists (N-3),
//  pinned questions (N-11), case issues (N-1), review codes (N-4), custom record
//  types (N-12) and alerts (W3-4). Removals stamp a time; nothing is deleted.
//

import Foundation

// MARK: - Watchlists (N-3)

public nonisolated struct Watchlist: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let terms: [String]
}

public actor WatchlistRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func create(name: String, terms: [String]) async throws -> UUID {
        let id = UUID(); let now = Date()
        let clean = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        try await database.withSavepoint("watchlist_create") { db in
            try db.exec("INSERT INTO watchlists (id, name, created_at) VALUES (?, ?, ?);", [.uuid(id), .text(name), .date(now)])
            for t in clean {
                try db.exec("INSERT INTO watchlist_entries (id, watchlist_id, term, created_at) VALUES (?, ?, ?, ?);",
                            [.uuid(UUID()), .uuid(id), .text(t), .date(now)])
            }
        }
        return id
    }

    public func all() async throws -> [Watchlist] {
        let lists = try await database.query("SELECT id, name FROM watchlists WHERE retired_at IS NULL ORDER BY name;", [])
        var out: [Watchlist] = []
        for l in lists {
            guard let id = l.uuid(0), let name = l.string(1) else { continue }
            let terms = try await database.query(
                "SELECT term FROM watchlist_entries WHERE watchlist_id = ? AND removed_at IS NULL ORDER BY term;", [.uuid(id)])
                .compactMap { $0.string(0) }
            out.append(Watchlist(id: id, name: name, terms: terms))
        }
        return out
    }

    public func retire(_ id: UUID) async throws {
        try await database.exec("UPDATE watchlists SET retired_at = ? WHERE id = ?;", [.date(Date()), .uuid(id)])
    }
}

// MARK: - Pinned questions (N-11)

public nonisolated struct PinnedQuestion: Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public let lastCheckedAt: Date?
    public let lastAnswer: String?
    public let lastFingerprint: String?
    public let lastCitationIDs: [UUID]
    public let lastContradictions: Int?
}

public actor PinnedQuestionsRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func pin(_ question: String) async throws -> UUID {
        let id = UUID()
        try await database.exec("INSERT INTO pinned_questions (id, question, created_at) VALUES (?, ?, ?);",
                                [.uuid(id), .text(question), .date(Date())])
        return id
    }

    public func all() async throws -> [PinnedQuestion] {
        try await database.query("""
            SELECT id, question, last_checked_at, last_answer_text, last_answer_fingerprint, last_citation_ids, last_contradictions
            FROM pinned_questions WHERE retired_at IS NULL ORDER BY created_at;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let q = r.string(1) else { return nil }
            return PinnedQuestion(id: id, question: q, lastCheckedAt: r.double(2).map { Date(timeIntervalSince1970: $0) },
                                  lastAnswer: r.string(3), lastFingerprint: r.string(4),
                                  lastCitationIDs: (r.string(5) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) },
                                  lastContradictions: r.int(6).map { Int($0) })
        }
    }

    public func record(_ id: UUID, answer: String, fingerprint: String, citations: [UUID], contradictions: Int) async throws {
        try await database.exec("""
            UPDATE pinned_questions SET last_checked_at = ?, last_answer_text = ?, last_answer_fingerprint = ?,
                   last_citation_ids = ?, last_contradictions = ? WHERE id = ?;
            """, [.date(Date()), .text(answer), .text(fingerprint),
                  .text(citations.map(\.uuidString).joined(separator: ",")), .integer(Int64(contradictions)), .uuid(id)])
    }

    public func unpin(_ id: UUID) async throws {
        try await database.exec("UPDATE pinned_questions SET retired_at = ? WHERE id = ?;", [.date(Date()), .uuid(id)])
    }
}

// MARK: - Case issues (N-1)

public nonisolated struct CaseIssue: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let description: String?
}

public nonisolated enum IssueSubjectKind: String, Sendable { case event, fact, object, chunk }

public actor CaseIssuesRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func create(name: String, description: String?) async throws -> UUID {
        let id = UUID()
        try await database.exec("INSERT INTO case_issues (id, name, description, created_at) VALUES (?, ?, ?, ?);",
                                [.uuid(id), .text(name), description.map { .text($0) } ?? .null, .date(Date())])
        return id
    }

    public func all() async throws -> [CaseIssue] {
        try await database.query("SELECT id, name, description FROM case_issues WHERE retired_at IS NULL ORDER BY name;", [])
            .compactMap { r in r.uuid(0).flatMap { id in r.string(1).map { CaseIssue(id: id, name: $0, description: r.string(2)) } } }
    }

    public func link(_ issue: UUID, _ kind: IssueSubjectKind, _ subject: UUID) async throws {
        try await database.exec("""
            INSERT INTO case_issue_links (issue_id, subject_kind, subject_id, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (issue_id, subject_kind, subject_id) DO UPDATE SET removed_at = NULL;
            """, [.uuid(issue), .text(kind.rawValue), .uuid(subject), .date(Date())])
    }

    public func unlink(_ issue: UUID, _ kind: IssueSubjectKind, _ subject: UUID) async throws {
        try await database.exec("""
            UPDATE case_issue_links SET removed_at = ? WHERE issue_id = ? AND subject_kind = ? AND subject_id = ? AND removed_at IS NULL;
            """, [.date(Date()), .uuid(issue), .text(kind.rawValue), .uuid(subject)])
    }

    public func subjects(of issue: UUID, kind: IssueSubjectKind) async throws -> [UUID] {
        try await database.query("""
            SELECT subject_id FROM case_issue_links WHERE issue_id = ? AND subject_kind = ? AND removed_at IS NULL;
            """, [.uuid(issue), .text(kind.rawValue)]).compactMap { $0.uuid(0) }
    }

    public func issues(for kind: IssueSubjectKind, _ subject: UUID) async throws -> [CaseIssue] {
        try await database.query("""
            SELECT i.id, i.name, i.description FROM case_issue_links l JOIN case_issues i ON i.id = l.issue_id
            WHERE l.subject_kind = ? AND l.subject_id = ? AND l.removed_at IS NULL AND i.retired_at IS NULL;
            """, [.text(kind.rawValue), .uuid(subject)])
            .compactMap { r in r.uuid(0).flatMap { id in r.string(1).map { CaseIssue(id: id, name: $0, description: r.string(2)) } } }
    }
}

// MARK: - Review codes (N-4)

public nonisolated enum ReviewCode: String, Sendable, CaseIterable, Identifiable {
    case responsive, notResponsive = "not_responsive", privileged, hot
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .responsive: return "Responsive"
        case .notResponsive: return "Not responsive"
        case .privileged: return "Privileged"
        case .hot: return "Hot"
        }
    }
}

public actor ReviewCodesRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The current code replaces the previous one (the old row is stamped removed, kept).
    public func setCode(_ code: ReviewCode, for object: UUID, reviewer: String = "user") async throws {
        let now = Date()
        try await database.withSavepoint("review_code_set") { db in
            try db.exec("UPDATE review_codes SET removed_at = ? WHERE object_id = ? AND removed_at IS NULL;", [.date(now), .uuid(object)])
            try db.exec("INSERT INTO review_codes (id, object_id, code, reviewer, coded_at) VALUES (?, ?, ?, ?, ?);",
                        [.uuid(UUID()), .uuid(object), .text(code.rawValue), .text(reviewer), .date(now)])
        }
    }

    public func current() async throws -> [UUID: ReviewCode] {
        var out: [UUID: ReviewCode] = [:]
        for r in try await database.query("SELECT object_id, code FROM review_codes WHERE removed_at IS NULL;", []) {
            if let id = r.uuid(0), let c = r.string(1).flatMap(ReviewCode.init(rawValue:)) { out[id] = c }
        }
        return out
    }
}

// MARK: - Custom record types (N-12)

public nonisolated struct CustomRecordType: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let fields: [String]
}

public actor CustomRecordTypesRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func create(name: String, fields: [String]) async throws -> UUID {
        let id = UUID()
        let json = String(data: try JSONEncoder().encode(fields), encoding: .utf8) ?? "[]"
        try await database.exec("INSERT INTO custom_record_types (id, name, fields_json, created_at) VALUES (?, ?, ?, ?);",
                                [.uuid(id), .text(name), .text(json), .date(Date())])
        return id
    }

    public func all() async throws -> [CustomRecordType] {
        try await database.query("SELECT id, name, fields_json FROM custom_record_types WHERE retired_at IS NULL ORDER BY name;", [])
            .compactMap { r in
                guard let id = r.uuid(0), let name = r.string(1) else { return nil }
                let fields = (try? JSONDecoder().decode([String].self, from: Data((r.string(2) ?? "[]").utf8))) ?? []
                return CustomRecordType(id: id, name: name, fields: fields)
            }
    }
}

// MARK: - Alerts (W3-4)

public nonisolated struct ProductAlert: Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let title: String
    public let detail: String?
    public let objectID: UUID?
    public let createdAt: Date
    public let read: Bool
}

public actor ProductAlertsRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public func add(kind: String, title: String, detail: String?, objectID: UUID?) async throws {
        try await database.exec("""
            INSERT INTO product_alerts (id, kind, title, detail, object_id, created_at) VALUES (?, ?, ?, ?, ?, ?);
            """, [.uuid(UUID()), .text(kind), .text(title), detail.map { .text($0) } ?? .null,
                  objectID.map { .uuid($0) } ?? .null, .date(Date())])
    }

    public func recent(limit: Int = 100) async throws -> [ProductAlert] {
        try await database.query("""
            SELECT id, kind, title, detail, object_id, created_at, read_at FROM product_alerts ORDER BY created_at DESC LIMIT ?;
            """, [.integer(Int64(limit))]).compactMap { r in
            guard let id = r.uuid(0), let t = r.double(5) else { return nil }
            return ProductAlert(id: id, kind: r.string(1) ?? "", title: r.string(2) ?? "", detail: r.string(3),
                                objectID: r.uuid(4), createdAt: Date(timeIntervalSince1970: t), read: r.double(6) != nil)
        }
    }

    public func unreadCount() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM product_alerts WHERE read_at IS NULL;", []).first?.int(0) ?? 0)
    }

    public func markAllRead() async throws {
        try await database.exec("UPDATE product_alerts SET read_at = ? WHERE read_at IS NULL;", [.date(Date())])
    }
}
