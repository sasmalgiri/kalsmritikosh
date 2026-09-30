//
//  SQLiteAcquisitionDeadlineTests.swift
//  KalsmritikoshTests
//
//  F03 (remaining fixes, 2026-09-29 review of 39e64d6) — the online-backup loop retried a BUSY /
//  LOCKED source forever: the connection busy timeout bounds ONE attempt, not the loop. A source held
//  under an exclusive lock therefore never finished acquiring and never reached its fallback. The
//  loop now has an overall deadline, bounded backoff and cancellation; failures are typed, retryable,
//  close every handle and leave no partial destination.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F03 — SQLite acquisition waits on a locked source for a bounded time only", .serialized)
struct SQLiteAcquisitionDeadlineTests {

    /// A WAL database with rows in the main file AND committed rows that live only in the WAL.
    private func walSource(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("live.db")
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        for s in ["PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;",
                  "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);", "INSERT INTO t VALUES(1,'main-row');",
                  "PRAGMA wal_checkpoint(TRUNCATE);", "INSERT INTO t VALUES(2,'wal-only-row');"] {
            #expect(sqlite3_exec(h, s, nil, nil, nil) == SQLITE_OK, "\(s)")
        }
        return url
    }

    /// A second connection that holds the database under an EXCLUSIVE lock (WAL readers are blocked
    /// only in exclusive locking mode, which is what an app holding its store exclusively does).
    private final class LockHolder: @unchecked Sendable {
        private var db: OpaquePointer?
        init(_ url: URL) {
            sqlite3_open(url.path, &db)
            sqlite3_exec(db, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil)
            sqlite3_exec(db, "BEGIN EXCLUSIVE;", nil, nil, nil)
            sqlite3_exec(db, "INSERT INTO t VALUES(3,'holder-row');", nil, nil, nil)
        }
        func release() {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA locking_mode=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "SELECT 1 FROM t LIMIT 1;", nil, nil, nil)   // a read drops the exclusive lock
            sqlite3_close(db); db = nil
        }
        deinit { if db != nil { sqlite3_close(db) } }
    }

    /// Releases the holder at the first LOCK-RETRY check (the acquisition also consults `isCancelled`
    /// before hashing and before the backup starts — calls 1 and 2); never reports cancellation.
    private final class ReleaseBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let holder: LockHolder
        private var calls = 0
        private(set) var fired = false
        init(_ holder: LockHolder) { self.holder = holder }
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls >= 3, !fired { fired = true; holder.release() }
            return false
        }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acqdl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rows(_ url: URL) -> [String] {
        var h: OpaquePointer?; var st: OpaquePointer?; var out: [String] = []
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(h) }
        sqlite3_prepare_v2(h, "SELECT v FROM t ORDER BY id;", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(st, 0))) }
        sqlite3_finalize(st)
        return out
    }

    @Test("An exclusively locked source ends with a typed retryable error at the deadline, leaving no partial file")
    func lockedSourceTimesOut() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try walSource(in: dir)
        let holder = LockHolder(source); defer { holder.release() }
        let dest = dir.appendingPathComponent("snap.db")
        let started = Date()
        #expect(throws: SourceIntakeError.self) {
            _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 0.4, maxBackoff: 0.05))
        }
        do { _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 0.4, maxBackoff: 0.05)) }
        catch SourceIntakeError.acquisitionTimedOut(let url, _) { #expect(url == source) }
        catch { Issue.record("expected acquisitionTimedOut, got \(error)") }
        #expect(Date().timeIntervalSince(started) < 20, "the wait is bounded by the deadline (the old loop never ended; slack for loaded CI)")
        #expect(!FileManager.default.fileExists(atPath: dest.path), "no partial destination survives")
        #expect(!FileManager.default.fileExists(atPath: dest.path + "-journal"))
    }

    @Test("A lock released while the acquisition waits: the next attempt succeeds with every committed row")
    func releasedWithinDeadline() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try walSource(in: dir)
        let holder = LockHolder(source)
        // Deterministic barrier (no timer — a loaded CI runner starved the old timed release): the
        // acquisition consults `isCancelled` before every retry, i.e. only after it has met the lock;
        // the lock is released there, once, so the next fresh attempt must succeed.
        let barrier = ReleaseBarrier(holder)
        let dest = dir.appendingPathComponent("snap.db")
        let record: SQLiteAcquisition.Record
        do {
            record = try SQLiteAcquisition.acquire(source, into: dest,
                                                   limits: .init(deadline: 60, maxBackoff: 0.05, isCancelled: { barrier.fire() }))
        }
        catch {
            let fm = FileManager.default
            Issue.record("acquisition after release failed: \(error); -wal present: \(fm.fileExists(atPath: source.path + "-wal")), -shm present: \(fm.fileExists(atPath: source.path + "-shm")), SQLite \(String(cString: sqlite3_libversion()))")
            return
        }
        #expect(record.method == "sqliteOnlineBackup")
        #expect(barrier.fired, "the acquisition met the lock before it was released")
        #expect(rows(dest) == ["main-row", "wal-only-row", "holder-row"], "committed WAL rows included")
    }

    @Test("A WAL-mode database at rest (no -wal, no -shm) acquires — it is not a lock to wait out")
    func atRestWALModeDatabaseAcquires() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // At rest: every commit checkpointed into the main file, no connection open, no sidecars (e.g. a
        // WAL-mode database copied without them). Apple's SQLite may keep a -wal/-shm after close, so the
        // state is made explicit.
        let source = try walSource(in: dir)
        var h: OpaquePointer?
        #expect(sqlite3_open(source.path, &h) == SQLITE_OK)
        #expect(sqlite3_exec(h, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        try? FileManager.default.removeItem(atPath: source.path + "-wal")
        try? FileManager.default.removeItem(atPath: source.path + "-shm")
        #expect(SQLiteAcquisition.needsLogicalAcquisition(source), "fixture: the header is still WAL mode")
        let dest = dir.appendingPathComponent("snap.db")
        let started = Date()
        _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 5, maxBackoff: 0.05))
        #expect(Date().timeIntervalSince(started) < 4, "no waiting on a lock nobody holds")
        #expect(rows(dest) == ["main-row", "wal-only-row"])
    }

    @Test("Cancellation during the lock wait exits promptly and cleans up")
    func cancelledWhileWaiting() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try walSource(in: dir)
        let holder = LockHolder(source); defer { holder.release() }
        let dest = dir.appendingPathComponent("snap.db")
        let started = Date()
        let task = Task.detached { () -> Error? in
            do { _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 60, maxBackoff: 0.05)); return nil }
            catch { return error }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let error = await task.value
        #expect(error as? SourceIntakeError == .acquisitionCancelled(source))
        #expect(Date().timeIntervalSince(started) < 20, "cancel is honoured long before the 60 s deadline (slack for loaded CI)")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("A retry after a timed-out attempt produces a fresh, valid snapshot — never the stale destination")
    func retryAfterFailure() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try walSource(in: dir)
        let dest = dir.appendingPathComponent("snap.db")
        try Data("not a database — left over from an earlier attempt".utf8).write(to: dest)
        let holder = LockHolder(source)
        #expect(throws: SourceIntakeError.self) {
            _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 0.3, maxBackoff: 0.05))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "the stale destination is removed, not kept")
        holder.release()
        _ = try SQLiteAcquisition.acquire(source, into: dest, limits: .init(deadline: 5))
        #expect(rows(dest) == ["main-row", "wal-only-row", "holder-row"])
        #expect(Database.quickCheck(fileAt: dest) == nil)
    }
}
