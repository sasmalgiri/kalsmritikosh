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
import OSLog
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

    /// Transaction serialization gate. Without this, two concurrent
    /// callers can both call `exec("BEGIN IMMEDIATE;")` between each
    /// other's `await`s — SQLite sees the second BEGIN as nested and
    /// raises "cannot start a transaction within a transaction".
    /// Repository writes that wrap a multi-await BEGIN/COMMIT block
    /// MUST acquire the gate via `beginTransaction()` first, releasing
    /// it via `commitTransaction()` or `rollbackTransaction()`.
    internal var transactionInProgress = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Ask snapshot (unit C-ii read-split, owner bindings 2026-09-01)
    //
    // The answer path's evidence reads go through a SECOND, read-only WAL
    // connection holding one read transaction per ask: in-flight asks see a
    // stable world; writes (answer commits, distillation) land on the main
    // connection and become visible BETWEEN asks, never during. The ledger
    // commit read-back (lockVerifiedFinal validating its own row mid-ask)
    // uses `liveQuery` explicitly — the ONLY sanctioned live read during a
    // snapshot; the audit counter below catches any other (binding #4).
    internal var snapshotHandle: OpaquePointer?
    internal var askSnapshotActive = false
    /// Nesting depth of active savepoints — savepoint-scoped reads route
    /// live (read-your-own-writes), everything else snapshots during an ask.
    internal var inSavepoint = 0
    /// Completeness audit: live-connection reads issued while a snapshot is
    /// active. Expected = the ledger read-backs only; anything else is a
    /// silently reintroduced leak.
    public private(set) var liveReadsDuringSnapshot = 0

    public var isAskSnapshotActive: Bool { askSnapshotActive }

    internal func noteLiveReadDuringSnapshot() { liveReadsDuringSnapshot += 1 }

    /// Open (lazily) the read-only connection, begin one read transaction,
    /// and return the ledger-state stamp read ON THE SNAPSHOT CONNECTION at
    /// that instant (binding #3: the stamp and the snapshot are the same
    /// moment by construction). nil when a snapshot is already active or
    /// the connection cannot open — callers degrade to live reads.
    public func beginAskSnapshot() -> Int64? {
        guard !askSnapshotActive else { return nil }
        if snapshotHandle == nil {
            var db: OpaquePointer?
            let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let opened = db else {
                sqlite3_close(db)
                return nil
            }
            try? Self.execRaw(handle: opened, sql: "PRAGMA busy_timeout=30000;")
            snapshotHandle = opened
        }
        guard let snap = snapshotHandle else { return nil }
        guard (try? Self.execRaw(handle: snap, sql: "BEGIN;")) != nil else { return nil }
        var stamp: Int64?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(snap, "PRAGMA data_version;", -1, &stmt, nil) == SQLITE_OK, let prepared = stmt {
            if sqlite3_step(prepared) == SQLITE_ROW { stamp = sqlite3_column_int64(prepared, 0) }
            sqlite3_finalize(prepared)
        }
        askSnapshotActive = true
        return stamp
    }

    /// Release the ask's read transaction — UNCONDITIONALLY safe (binding
    /// #3: defer-style at ask end; a lingering read txn pins WAL growth).
    public func endAskSnapshot() {
        defer { askSnapshotActive = false }
        guard askSnapshotActive, let snap = snapshotHandle else { return }
        try? Self.execRaw(handle: snap, sql: "COMMIT;")
    }

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

        // G2-SWIFT6 — the actor `init` is nonisolated (it must be, to
        // bootstrap the actor's state). Calling the actor-isolated
        // `execRaw` from here trips the strict-concurrency warning.
        // Route the pragma setup through the static helper instead —
        // it takes the raw handle directly so no actor isolation is
        // needed. Both paths converge on `Self.execRaw(handle:sql:)`.
        try Self.execRaw(handle: db, sql: "PRAGMA journal_mode=WAL;")
        try Self.execRaw(handle: db, sql: "PRAGMA foreign_keys=ON;")
        try Self.execRaw(handle: db, sql: "PRAGMA synchronous=NORMAL;")
        // CRITICAL: without busy_timeout SQLite returns SQLITE_BUSY
        // immediately on any lock contention. During concurrent
        // ingestion (mbox per-message inserts overlapping with PDF
        // chunk writes, distillation writes, FTS trigger updates) we
        // observed ~75% of mbox KO inserts silently failing — the
        // per-KO catch in IngestCoordinator was swallowing the
        // "database is locked" errors. 30 s gives SQLite room to wait
        // out any in-flight transaction without raising.
        try Self.execRaw(handle: db, sql: "PRAGMA busy_timeout=30000;")
        // PERF-1 — modern read tuning, all zero-dependency and reversible:
        //  • mmap_size: memory-map up to 256 MB of the DB so large sequential
        //    reads (FTS scans, vector/posting range reads, migration walks)
        //    avoid read() syscall + buffer-copy overhead. Best-effort — SQLite
        //    silently caps to what the platform allows and falls back to
        //    normal I/O, so this can only help.
        //  • cache_size: negative = KiB, so -20000 ≈ 20 MB page cache (up from
        //    the ~2 MB default), cutting page re-reads on repeated queries.
        //  • temp_store=MEMORY: keep transient sort/GROUP BY/index-build spills
        //    in RAM rather than a temp file. All bounded, none affect
        //    durability (WAL + synchronous=NORMAL unchanged).
        try? Self.execRaw(handle: db, sql: "PRAGMA mmap_size=268435456;")
        try? Self.execRaw(handle: db, sql: "PRAGMA cache_size=-20000;")
        try? Self.execRaw(handle: db, sql: "PRAGMA temp_store=MEMORY;")
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

    /// Run `body` inside a named SAVEPOINT as ONE non-interleavable actor operation
    /// (OPS-002.2). The closure is SYNCHRONOUS and receives this database as an `isolated`
    /// parameter, so it can call the isolated `exec`/`query` helpers directly with NO
    /// suspension points — no other work on this connection can execute between the
    /// closure's validations and its writes. This is the required shape for
    /// validate-then-write invariants (e.g. deadline confirmation): an ordinary
    /// query-before-SAVEPOINT can be invalidated by an interleaved writer; a synchronous
    /// isolated closure cannot. Any throw rolls the entire savepoint back.
    public func withSavepoint<T: Sendable>(
        _ name: String,
        _ body: @Sendable (isolated Database) throws -> T
    ) throws -> T {
        // UNIT C-ii: savepoint bodies are read-your-own-writes territory by
        // definition (the ledger commit validates rows it just wrote), so
        // reads inside them route LIVE even while an ask snapshot is active —
        // the structural form of the "commit reads stay live" split.
        inSavepoint += 1
        defer { inSavepoint -= 1 }
        try execRaw("SAVEPOINT \(name);")
        do {
            let result = try body(self)
            try execRaw("RELEASE SAVEPOINT \(name);")
            return result
        } catch {
            try? execRaw("ROLLBACK TO SAVEPOINT \(name);")
            try? execRaw("RELEASE SAVEPOINT \(name);")
            throw error
        }
    }

    /// Acquire the transaction gate and start a SQLite transaction.
    /// Waits (suspending the caller, not blocking the actor) until any
    /// prior transaction has called `commitTransaction()` or
    /// `rollbackTransaction()`. Required for any repository pattern that
    /// awaits between BEGIN and COMMIT — without this gate, concurrent
    /// callers race and SQLite raises "cannot start a transaction
    /// within a transaction".
    ///
    /// Hand-off semantics: when a transaction releases the gate, it
    /// resumes the next waiter directly (keeping `transactionInProgress`
    /// = true). The woken waiter inherits the gate without re-racing
    /// against any newly-arriving caller, avoiding starvation.
    public func beginTransaction() async throws {
        if transactionInProgress {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                transactionWaiters.append(cont)
            }
            // On resume the gate has been handed to us — transactionInProgress
            // is still true (set by the previous owner's release).
        } else {
            transactionInProgress = true
        }
        do {
            try execRaw("BEGIN IMMEDIATE;")
        } catch {
            releaseGate()
            throw error
        }
    }

    public func commitTransaction() throws {
        defer { releaseGate() }
        try execRaw("COMMIT;")
    }

    public func rollbackTransaction() {
        defer { releaseGate() }
        try? execRaw("ROLLBACK;")
    }

    /// Hand the gate to the next waiter (if any), or clear the flag.
    private func releaseGate() {
        if !transactionWaiters.isEmpty {
            let next = transactionWaiters.removeFirst()
            // Keep transactionInProgress = true so a newly-arriving caller
            // queues behind the woken waiter rather than racing past it.
            next.resume()
        } else {
            transactionInProgress = false
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
        try Self.execRaw(handle: rawHandle, sql: sql)
    }

    /// Nonisolated raw-exec helper. Used from the actor `init` (where
    /// the actor isn't shared yet so accessing rawHandle is safe) AND
    /// from the actor-isolated `execRaw` instance method above. Single
    /// shared body avoids drift.
    private static func execRaw(handle: OpaquePointer?, sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
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
    /// Current container folder name under Application Support.
    static let containerName = "KalsmritikoshChronicaMemora"
    /// The pre-rename folder. Kept as ONE explicit reference solely so the
    /// one-time migration below can move an existing archive into the new
    /// location — no data is lost by the Atlas→Kalsmritikosh rename. Safe to
    /// delete this constant + `migrateLegacyContainerIfNeeded()` in a future
    /// release once all installs have migrated.
    private static let legacyContainerName = "AtlasChronicaMemora"

    public static var defaultDatabaseURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        migrateLegacyContainerIfNeeded(under: appSupport)
        return appSupport
            .appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent("knowledge.sqlite", isDirectory: false)
    }

    /// One-time rename migration: if the new container doesn't exist yet but
    /// the legacy `AtlasChronicaMemora` folder does, move it across so the
    /// user's existing ledger (DB, vectors, models, caches) is preserved.
    /// Idempotent — a no-op once the new folder exists.
    private static func migrateLegacyContainerIfNeeded(under appSupport: URL) {
        let fm = FileManager.default
        let newDir = appSupport.appendingPathComponent(containerName, isDirectory: true)
        let legacyDir = appSupport.appendingPathComponent(legacyContainerName, isDirectory: true)
        guard !fm.fileExists(atPath: newDir.path),
              fm.fileExists(atPath: legacyDir.path) else { return }
        do {
            try fm.moveItem(at: legacyDir, to: newDir)
            KalsmritikoshLog.storage.info("Migrated legacy container \(legacyContainerName, privacy: .public) → \(containerName, privacy: .public)")
        } catch {
            // Fall back to a copy so a move failure never blocks boot or loses
            // data; the app then reads/writes the new dir, legacy stays as backup.
            try? fm.copyItem(at: legacyDir, to: newDir)
            KalsmritikoshLog.storage.error("Legacy container move failed, copied instead: \(String(describing: error), privacy: .public)")
        }
    }
}
