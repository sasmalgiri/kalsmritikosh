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

    /// F28 — the ONE transaction ownership model for this shared connection: every transaction is
    /// `withSavepoint`, a synchronous isolated body with no suspension point. There is deliberately
    /// no await-spanning BEGIN/COMMIT API: a gate honoured by only some writers let every other
    /// caller's write run inside an open transaction and vanish when it rolled back.
    /// `RawSavepointRatchetTests.noAwaitSpanningTransactionAPI` fails if one is reintroduced.

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
        // Pin the WAL read snapshot with a GUARANTEED read — SQLite takes the
        // read snapshot at the first SELECT in a deferred transaction, so the
        // isolation must not depend on the (schema-dependent) stamp query
        // below succeeding. data_version is always present.
        try? Self.execRaw(handle: snap, sql: "PRAGMA data_version;")
        // EVIDENCE-STATE STAMP (owner ruling 2026-09-02): the contract says
        // the stamp measures EVIDENCE mutation — but PRAGMA data_version bumps
        // on ANY write, including lawful cache/exhaust inserts (embedding_cache,
        // memory_objects, answer_revision_events). Those warm-the-cache writes
        // must NOT read as a world change, so a cold-cache ask and a warm-cache
        // ask over identical evidence would stamp differently and the parity
        // contract would smear. Stamp is therefore a row-count sum over the
        // EVIDENCE tables only — cache and exhaust excluded by construction —
        // read on the snapshot connection (the ask-start evidence world).
        var stamp: Int64 = 0
        var stmt: OpaquePointer?
        let stampSQL = "SELECT (SELECT COUNT(*) FROM knowledge_objects)+(SELECT COUNT(*) FROM chunks)+(SELECT COUNT(*) FROM generic_facts)+(SELECT COUNT(*) FROM entities)+(SELECT COUNT(*) FROM events);"
        if sqlite3_prepare_v2(snap, stampSQL, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt {
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

    public enum BackupSnapshotError: Error, Sendable {
        case openFailed(String)
        case stepFailed(String)
        case verifyFailed(String)
    }

    /// F18 — a CONSISTENT copy of the live ledger via SQLite's Online Backup API
    /// (https://www.sqlite.org/backup.html), written to `destination` as ONE self-contained file
    /// (WAL content included; no sidecars). It runs as a single synchronous actor operation, so no
    /// write on this connection can interleave, and SQLite itself guarantees the copy is a coherent
    /// point-in-time image even while other connections are active (busy/locked pages are retried).
    /// The finished file must pass `quick_check` or it is deleted and the call throws.
    public func backupSnapshot(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        var dest: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destDB = dest else {
            let msg = dest.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open destination"
            sqlite3_close(dest)
            throw BackupSnapshotError.openFailed(msg)
        }
        var failure: String?
        if let backup = sqlite3_backup_init(destDB, "main", rawHandle, "main") {
            var rc: Int32
            repeat {
                rc = sqlite3_backup_step(backup, -1)
                if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(25) }
            } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
            if rc != SQLITE_DONE { failure = String(cString: sqlite3_errmsg(destDB)) }
            sqlite3_backup_finish(backup)
        } else {
            failure = String(cString: sqlite3_errmsg(destDB))
        }
        if failure == nil, sqlite3_errcode(destDB) != SQLITE_OK { failure = String(cString: sqlite3_errmsg(destDB)) }
        // The copy inherits the live WAL mode; switch it to a rollback journal so the snapshot is ONE
        // self-contained file that opens anywhere without -wal/-shm sidecars.
        if failure == nil, sqlite3_exec(destDB, "PRAGMA journal_mode=DELETE;", nil, nil, nil) != SQLITE_OK {
            failure = String(cString: sqlite3_errmsg(destDB))
        }
        sqlite3_close(destDB)
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            throw BackupSnapshotError.stepFailed(failure)
        }
        if let problem = Self.quickCheck(fileAt: destination) {
            try? FileManager.default.removeItem(at: destination)
            throw BackupSnapshotError.verifyFailed(problem)
        }
    }

    /// F19 — open a database file READ-ONLY (never modifying it), run `PRAGMA quick_check`, close.
    /// Returns nil when the file is a sound SQLite database, else the failure text. Used to vet a
    /// staged restore before it may replace anything; the raw handle never leaves this function.
    public nonisolated static func quickCheck(fileAt url: URL) -> String? {
        var db: OpaquePointer?
        // `immutable=1`: read the file as-is — no locks, no -shm creation, never a write.
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "file"
        comps?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let uri = comps?.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            return msg
        }
        defer { sqlite3_close(opened) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            return String(cString: sqlite3_errmsg(opened))
        }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_ROW, let text = sqlite3_column_text(prepared, 0) else {
            return String(cString: sqlite3_errmsg(opened))
        }
        let result = String(cString: text)
        return result == "ok" ? nil : result
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
        if let snapshotHandle { sqlite3_close_v2(snapshotHandle) }
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
        // C-ii: release the snapshot connection too — deleting a VACUUM
        // copy while it stays open logs "vnode unlinked while in use".
        if let snap = snapshotHandle {
            if askSnapshotActive { try? Self.execRaw(handle: snap, sql: "COMMIT;") }
            askSnapshotActive = false
            sqlite3_close_v2(snap)
            snapshotHandle = nil
        }
        guard let handle = rawHandle else { return }
        sqlite3_close_v2(handle)
        rawHandle = nil
    }

    // MARK: - Exec / Query

    public func exec(_ sql: String) throws {
        try execRaw(sql)
    }

    /// Fold the write-ahead log back into the main database file and truncate
    /// it, so `knowledge.sqlite` is SELF-CONTAINED on disk.
    ///
    /// This connection runs `PRAGMA journal_mode=WAL`, which means recent
    /// commits can live entirely in `knowledge.sqlite-wal`. Anything that
    /// copies only the main file — the backup feature does exactly that — would
    /// silently produce a copy missing the newest writes, while its SHA-256
    /// manifest made the copy look verified. Call this first.
    ///
    /// Returns true when the log is fully checkpointed. A `false` return means
    /// a reader or writer held the log open and the main file is NOT complete;
    /// the caller must not present that as a clean backup.
    @discardableResult
    public func checkpointWAL() throws -> Bool {
        var busy = true
        try withStatement("PRAGMA wal_checkpoint(TRUNCATE);") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                // Column 0 is the busy flag: 0 = the whole log was written back.
                busy = sqlite3_column_int(stmt, 0) != 0
            }
        }
        return !busy
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
