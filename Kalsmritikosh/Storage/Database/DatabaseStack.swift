//
//  DatabaseStack.swift
//  Kalsmritikosh
//
//  SQLite is the single source of truth (Files, Chunks, KnowledgeObjects,
//  Entities, Events, Timelines, Relationships, Summaries, Conversations,
//  Projects, Companies, People — and the sqlite-vec embedding table).
//
//  M0 uses the SQLite3 C API straight from Darwin so we ship without an
//  SPM gate. The `Database` facade is the swap point: a later milestone
//  can drop in GRDB.swift behind it without touching callers.
//

import Foundation
import SQLite3

/// Errors surfaced by the SQLite layer. Carries the underlying SQLite
/// message for debugging during development.
public enum DatabaseError: Error, Sendable {
    case openFailed(message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case migrationFailed(version: Int, message: String)
    case extensionLoadFailed(name: String, message: String)
}

/// Sendable wrapper around an opaque `sqlite3` handle. We serialize all
/// access through `actor Database`, so the raw pointer never escapes.
public actor Database {
    internal var rawHandle: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw DatabaseError.openFailed(message: msg)
        }
        self.rawHandle = db

        try execRaw("PRAGMA journal_mode=WAL;")
        try execRaw("PRAGMA foreign_keys=ON;")
        try execRaw("PRAGMA synchronous=NORMAL;")
    }

    deinit {
        if let rawHandle {
            // v2 schedules cleanup if any statements are still alive;
            // v1 would leak the handle outright in that case.
            sqlite3_close_v2(rawHandle)
        }
    }

    /// Deterministically close the SQLite handle. The eval harness
    /// (Gate1Baseline) must call this *before* its `defer` removes the
    /// temp-dir DB file — otherwise the file unlinks while the handle
    /// is still open and macOS raises a `vnode unlinked while in use`
    /// warning per open fd, and ongoing queries get `invalidated open
    /// fd: N` errors. Idempotent: subsequent calls become no-ops.
    public func close() {
        guard let handle = rawHandle else { return }
        sqlite3_close_v2(handle)
        rawHandle = nil
    }

    // MARK: - Exec / Query

    public func exec(_ sql: String) throws {
        try execRaw(sql)
    }

    public func currentUserVersion() throws -> Int {
        var version: Int = 0
        try withStatement("PRAGMA user_version;") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    public func setUserVersion(_ value: Int) throws {
        try execRaw("PRAGMA user_version = \(value);")
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execRaw("BEGIN IMMEDIATE;")
        do {
            try body()
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }
    }

    // MARK: - sqlite-vec loader

    /// Apple's system `libsqlite3` is built with `SQLITE_OMIT_LOAD_EXTENSION`,
    /// so we can't call `sqlite3_load_extension` against it. The real
    /// sqlite-vec wire-up requires linking a custom-built SQLite (planned
    /// for M2 — either the official `swift-sqlite3` SPM package or a
    /// statically-linked sqlite-vec amalgamation). Until then this is a
    /// no-op and `SQLiteVectorStore` falls back to brute-force cosine.
    public func loadSqliteVecIfAvailable() {
        // Intentionally empty until M2 swaps in a custom SQLite build.
    }

    // MARK: - Internals

    internal func execRaw(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(rawHandle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.stepFailed(sql: sql, message: message)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(rawHandle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(rawHandle))
            throw DatabaseError.prepareFailed(sql: sql, message: msg)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }
}

/// Where the app stores its single SQLite file. Lives under
/// Application Support so it survives sandbox container migrations.
public enum DatabaseLocations {
    public static var defaultDatabaseURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return appSupport
            .appendingPathComponent("AtlasChronicaMemora", isDirectory: true)
            .appendingPathComponent("knowledge.sqlite", isDirectory: false)
    }
}
