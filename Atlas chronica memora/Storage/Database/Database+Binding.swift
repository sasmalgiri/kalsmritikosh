//
//  Database+Binding.swift
//  Atlas chronica memora
//
//  Thin parameter-binding helpers on top of the SQLite3 C API so the
//  repository layer reads as `try await db.exec("INSERT ...", [.text(...)])`
//  instead of pages of column-index math.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString) }
    public static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    public static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    public static func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }
    public static func optionalDate(_ value: Date?) -> SQLValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
}

public struct SQLRow: Sendable {
    public let values: [SQLValue]

    public func int(_ i: Int) -> Int64? {
        if case .integer(let v) = values[i] { return v }; return nil
    }
    public func double(_ i: Int) -> Double? {
        if case .real(let v) = values[i] { return v }; return nil
    }
    public func string(_ i: Int) -> String? {
        if case .text(let v) = values[i] { return v }; return nil
    }
    public func blob(_ i: Int) -> Data? {
        if case .blob(let v) = values[i] { return v }; return nil
    }
    public func uuid(_ i: Int) -> UUID? {
        guard let s = string(i) else { return nil }
        return UUID(uuidString: s)
    }
    public func date(_ i: Int) -> Date? {
        guard let d = double(i) else { return nil }
        return Date(timeIntervalSince1970: d)
    }
    public func isNull(_ i: Int) -> Bool {
        if case .null = values[i] { return true }
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

    /// Execute and collect rows.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        var rows: [SQLRow] = []
        try runBinding(sql: sql, bindings: bindings) { stmt in
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
        _ body: (OpaquePointer) -> Void
    ) throws {
        guard let raw = rawHandle else {
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
