//
//  ShellSessionRepository.swift
//  Kalsmritikosh
//
//  SHELL-001 (product shell) — the durable autosave/resume for the shell's location navigation history
//  (schema v95). saveHistory replaces a scope's session atomically (one SAVEPOINT: the whole entry stack
//  + the cursor are written together, so a relaunch never restores a torn history); loadHistory
//  reconstructs the exact AppNavigationHistory — same entries, same cursor — so the user resumes where
//  they left off. This is pure shell state: it touches none of the canonical evidence ledger.
//

import Foundation

public actor ShellSessionRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Autosave the navigation history for a scope (e.g. a workspace id or "default"). Atomic replace:
    /// the prior session (and its entries, via cascade) is removed and the current stack + cursor written.
    public func saveHistory(scopeKey: String, history: AppNavigationHistory, at date: Date) async throws {
        let clean = scopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ShellSessionError.blankScope }
        let sessionID = UUID()
        let sp = savepoint("shellsess", sessionID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let priorRevision = Int(try await database.query(
                "SELECT revision FROM app_navigation_sessions WHERE scope_key = ? LIMIT 1;", [.text(clean)]).first?.int(0) ?? 0)
            try await database.exec("DELETE FROM app_navigation_sessions WHERE scope_key = ?;", [.text(clean)])
            try await database.exec("""
                INSERT INTO app_navigation_sessions (id, scope_key, current_index, revision, updated_at)
                VALUES (?,?,?,?,?);
                """, [.uuid(sessionID), .text(clean), .integer(Int64(history.currentIndex)), .integer(Int64(priorRevision + 1)), .date(date)])
            for (ordinal, entry) in history.entries.enumerated() {
                try await database.exec("""
                    INSERT INTO app_navigation_entries (id, session_id, ordinal, destination, context_kind, context_id)
                    VALUES (?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(sessionID), .integer(Int64(ordinal)), .text(entry.destination.rawValue),
                          entry.contextKind.map { SQLValue.text($0) } ?? .null, entry.contextID.map { SQLValue.text($0) } ?? .null])
            }
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
    }

    /// Resume: reconstruct the exact navigation history for a scope, or nil if none was saved.
    public func loadHistory(scopeKey: String) async throws -> AppNavigationHistory? {
        let clean = scopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionRows = try await database.query(
            "SELECT id, current_index FROM app_navigation_sessions WHERE scope_key = ? LIMIT 1;", [.text(clean)])
        guard let row = sessionRows.first, let sessionID = row.uuid(0), let currentIndex = row.int(1).map({ Int($0) }) else { return nil }
        let entryRows = try await database.query("""
            SELECT destination, context_kind, context_id FROM app_navigation_entries
            WHERE session_id = ? ORDER BY ordinal ASC;
            """, [.uuid(sessionID)])
        let entries: [AppNavigationEntry] = entryRows.compactMap { r in
            guard let dest = r.string(0).flatMap(AppNavigationDestination.init(rawValue:)) else { return nil }
            return AppNavigationEntry(destination: dest, contextKind: r.string(1), contextID: r.string(2))
        }
        return AppNavigationHistory(entries: entries, currentIndex: currentIndex)
    }

    /// The revision counter for a scope's session (monotone per save; 0 when none) — for audit/tests.
    public func revision(scopeKey: String) async throws -> Int {
        Int(try await database.query("SELECT revision FROM app_navigation_sessions WHERE scope_key = ? LIMIT 1;",
                                     [.text(scopeKey.trimmingCharacters(in: .whitespacesAndNewlines))]).first?.int(0) ?? 0)
    }

    private nonisolated func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

public nonisolated enum ShellSessionError: Error, Sendable, Equatable {
    case blankScope
}
