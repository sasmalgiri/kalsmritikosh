//
//  Database+Binding.swift
//  Kalsmritikosh
//
//  Thin parameter-binding helpers on top of the SQLite3 C API so the
//  repository layer reads as `try await db.exec("INSERT ...", [.text(...)])`
//  instead of pages of column-index math.
//

import Foundation
import SQLite3

// G2-SWIFT6 — `nonisolated(unsafe)` so this top-level constant isn't
// inferred main-actor-isolated under strict concurrency. The value is
// a SQLite3 sentinel pointer that's immutable for the process
// lifetime; race conditions are not possible.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    // G2-SWIFT6 — every SQLValue static helper is nonisolated so it
    // can be called from any actor context. Pure value-producing funcs;
    // no mutable state, no isolation needed.
    nonisolated public static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString) }
    nonisolated public static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    nonisolated public static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    nonisolated public static func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }
    nonisolated public static func optionalDate(_ value: Date?) -> SQLValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
}

// G2-SWIFT6 — every SQLRow accessor needs `nonisolated` so repository
// actors can call them in synchronous context without tripping the
// strict-concurrency warning ("can not be called from outside of the
// actor"). SQLRow is a Sendable value type of immutable storage; no
// isolation is needed.
public struct SQLRow: Sendable {
    public let values: [SQLValue]

    public nonisolated init(values: [SQLValue]) {
        self.values = values
    }

    /// Bounds-checked accessor. Returns nil on out-of-range — a column
    /// mismatch should yield a missing field, not a fatal crash that
    /// takes the whole ingest task down.
    nonisolated private func value(at i: Int) -> SQLValue? {
        guard i >= 0, i < values.count else { return nil }
        return values[i]
    }

    nonisolated public func int(_ i: Int) -> Int64? {
        if case .integer(let v) = value(at: i) { return v }; return nil
    }
    nonisolated public func double(_ i: Int) -> Double? {
        if case .real(let v) = value(at: i) { return v }; return nil
    }
    nonisolated public func string(_ i: Int) -> String? {
        if case .text(let v) = value(at: i) { return v }; return nil
    }
    nonisolated public func blob(_ i: Int) -> Data? {
        if case .blob(let v) = value(at: i) { return v }; return nil
    }
    nonisolated public func uuid(_ i: Int) -> UUID? {
        guard let s = string(i) else { return nil }
        return UUID(uuidString: s)
    }
    nonisolated public func date(_ i: Int) -> Date? {
        guard let d = double(i) else { return nil }
        return Date(timeIntervalSince1970: d)
    }
    nonisolated public func isNull(_ i: Int) -> Bool {
        if case .null = value(at: i) { return true }
        return false
    }
}

extension Database {
    /// Execute a parameterized statement that returns no rows. Throws on
    /// SQLite step failures (constraint violations, FK errors, etc.) so
    /// callers don't silently miss bad writes.
    public func exec(_ sql: String, _ bindings: [SQLValue]) throws {
        var stepError: DatabaseError?
        try runBinding(sql: sql, bindings: bindings) { stmt in
            let rc = sqlite3_step(stmt)
            // SQLITE_DONE: terminal success for non-row statements.
            // SQLITE_ROW: legal too (e.g. INSERT ... RETURNING) — discard.
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                let msg = String(cString: sqlite3_errstr(rc))
                stepError = .stepFailed(sql: sql, message: msg)
            }
        }
        if let stepError { throw stepError }
    }

    /// Execute and collect rows. UNIT C-ii: while an ask snapshot is active,
    /// reads route to the snapshot connection BY CONSTRUCTION — evidence
    /// reads cannot see mid-ask writes; `liveQuery` is the explicit escape
    /// (ledger commit read-back only).
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        try collectRows(sql: sql, bindings: bindings,
                        handle: ((askSnapshotActive && inSavepoint == 0 && !transactionInProgress) ? snapshotHandle : nil) ?? rawHandle)
    }

    /// Read on the LIVE connection regardless of any active snapshot — for
    /// read-your-own-writes only (lockVerifiedFinal's commit proof). Counted
    /// while a snapshot is active (the completeness audit, binding #4).
    public func liveQuery(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        if askSnapshotActive { noteLiveReadDuringSnapshot() }
        return try collectRows(sql: sql, bindings: bindings, handle: rawHandle)
    }

    private func collectRows(sql: String, bindings: [SQLValue], handle: OpaquePointer?) throws -> [SQLRow] {
        var rows: [SQLRow] = []
        try runBinding(sql: sql, bindings: bindings, handle: handle) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_count(stmt))
                var vals: [SQLValue] = []
                vals.reserveCapacity(count)
                for c in 0..<count {
                    switch sqlite3_column_type(stmt, Int32(c)) {
                    case SQLITE_INTEGER:
                        vals.append(.integer(sqlite3_column_int64(stmt, Int32(c))))
                    case SQLITE_FLOAT:
                        vals.append(.real(sqlite3_column_double(stmt, Int32(c))))
                    case SQLITE_TEXT:
                        if let p = sqlite3_column_text(stmt, Int32(c)) {
                            vals.append(.text(String(cString: p)))
                        } else { vals.append(.null) }
                    case SQLITE_BLOB:
                        if let bp = sqlite3_column_blob(stmt, Int32(c)) {
                            let len = Int(sqlite3_column_bytes(stmt, Int32(c)))
                            vals.append(.blob(Data(bytes: bp, count: len)))
                        } else { vals.append(.null) }
                    default:
                        vals.append(.null)
                    }
                }
                rows.append(SQLRow(values: vals))
            }
        }
        return rows
    }

    public func scalar<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (SQLRow) -> T?) throws -> T? {
        let rows = try query(sql, bindings)
        guard let first = rows.first else { return nil }
        return map(first)
    }

    private func runBinding(
        sql: String,
        bindings: [SQLValue],
        handle: OpaquePointer?? = nil,
        _ body: (OpaquePointer) -> Void
    ) throws {
        guard let raw = (handle ?? rawHandle) else {
            throw DatabaseError.prepareFailed(sql: sql, message: "database not open")
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(raw))
            throw DatabaseError.prepareFailed(sql: sql, message: msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, v) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null:
                sqlite3_bind_null(stmt, idx)
            case .integer(let n):
                sqlite3_bind_int64(stmt, idx, n)
            case .real(let d):
                sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                _ = data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }

        body(stmt)
    }
}
