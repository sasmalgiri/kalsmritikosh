//
//  ExternalSQLiteSource.swift
//  Kalsmritikosh
//
//  Phase K — common helper for loaders that read external SQLite
//  files (chat.db, Safari History.db, Chrome History). All three
//  sources are live-locked while the owning app runs, so we never
//  open the file in place — we copy it to a temp directory first,
//  open the copy in `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`,
//  read, close, and clean up.
//
//  Also handles WAL: when the source has a `-wal` or `-shm`
//  sidecar, we copy those alongside so the read reflects committed
//  + pending state. (Apple's Messages and Chrome both use WAL.)
//
//  Quality-or-nothing: any failure (file missing, schema mismatch,
//  permission denied) throws; loaders refuse to substitute synthetic
//  data.
//

import Foundation
import SQLite3

public enum ExternalSQLiteError: Error, CustomStringConvertible {
    case copyFailed(URL, underlying: Error)
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .copyFailed(let url, let e):
            return "ExternalSQLite copy failed for \(url.lastPathComponent): \(e)"
        case .openFailed(let msg):
            return "ExternalSQLite open failed: \(msg)"
        case .prepareFailed(let msg):
            return "ExternalSQLite prepare failed: \(msg)"
        case .stepFailed(let msg):
            return "ExternalSQLite step failed: \(msg)"
        }
    }
}

/// Opens an external SQLite file safely (read-only, copy-first so
/// the owning app's writes don't conflict). Closes on `deinit`.
public final class ExternalSQLiteSource {
    private var handle: OpaquePointer?
    private let tempDir: URL

    /// Path of the temp copy (so callers can inspect or log it).
    public let copiedPath: URL

    public init(originalPath: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-extsqlite-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            throw ExternalSQLiteError.copyFailed(originalPath, underlying: error)
        }
        self.tempDir = tmp
        let dest = tmp.appendingPathComponent(originalPath.lastPathComponent)
        do {
            try fm.copyItem(at: originalPath, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw ExternalSQLiteError.copyFailed(originalPath, underlying: error)
        }
        // Copy WAL + SHM sidecars when present (Messages + Chrome use WAL).
        let walURL = URL(fileURLWithPath: originalPath.path + "-wal")
        let shmURL = URL(fileURLWithPath: originalPath.path + "-shm")
        if fm.fileExists(atPath: walURL.path) {
            try? fm.copyItem(at: walURL,
                             to: tmp.appendingPathComponent(walURL.lastPathComponent))
        }
        if fm.fileExists(atPath: shmURL.path) {
            try? fm.copyItem(at: shmURL,
                             to: tmp.appendingPathComponent(shmURL.lastPathComponent))
        }
        self.copiedPath = dest

        // Open the copy read-only. SQLITE_OPEN_PRIVATECACHE isolates
        // from any other handle in the process; SQLITE_OPEN_NOMUTEX
        // is safe because this class is single-threaded by design.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOMUTEX
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(dest.path, &h, flags, nil)
        if rc != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(h)
            try? fm.removeItem(at: tmp)
            throw ExternalSQLiteError.openFailed(msg)
        }
        self.handle = h
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Run a SELECT and return rows as `[[String: SQLValue]]`. Bind
    /// parameters are positional; pass an empty array when there
    /// are none.
    public func query(
        _ sql: String,
        binds: [Bind] = []
    ) throws -> [Row] {
        guard let handle else {
            throw ExternalSQLiteError.openFailed("handle closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw ExternalSQLiteError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        for (idx, bind) in binds.enumerated() {
            let pos = Int32(idx + 1)
            switch bind {
            case .int(let v):
                sqlite3_bind_int64(stmt, pos, Int64(v))
            case .int64(let v):
                sqlite3_bind_int64(stmt, pos, v)
            case .double(let v):
                sqlite3_bind_double(stmt, pos, v)
            case .text(let s):
                sqlite3_bind_text(stmt, pos, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null:
                sqlite3_bind_null(stmt, pos)
            }
        }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ExternalSQLiteError.stepFailed("rc=\(step)")
            }
            let colCount = Int(sqlite3_column_count(stmt))
            var cells: [Cell] = []
            cells.reserveCapacity(colCount)
            for i in 0..<colCount {
                let columnIndex = Int32(i)
                switch sqlite3_column_type(stmt, columnIndex) {
                case SQLITE_INTEGER:
                    cells.append(.int(sqlite3_column_int64(stmt, columnIndex)))
                case SQLITE_FLOAT:
                    cells.append(.double(sqlite3_column_double(stmt, columnIndex)))
                case SQLITE_TEXT:
                    if let cstr = sqlite3_column_text(stmt, columnIndex) {
                        cells.append(.text(String(cString: cstr)))
                    } else {
                        cells.append(.null)
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, columnIndex) {
                        let n = Int(sqlite3_column_bytes(stmt, columnIndex))
                        cells.append(.blob(Data(bytes: bytes, count: n)))
                    } else {
                        cells.append(.null)
                    }
                default:
                    cells.append(.null)
                }
            }
            rows.append(Row(cells: cells))
        }
        return rows
    }

    public enum Bind {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case text(String)
        case null
    }

    public enum Cell {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null

        public var int64: Int64? {
            if case .int(let v) = self { return v }
            return nil
        }
        public var double: Double? {
            switch self {
            case .double(let d): return d
            case .int(let v):    return Double(v)
            default:             return nil
            }
        }
        public var string: String? {
            if case .text(let s) = self { return s }
            return nil
        }
        public var data: Data? {
            if case .blob(let d) = self { return d }
            return nil
        }
    }

    public struct Row {
        public let cells: [Cell]

        public subscript(idx: Int) -> Cell {
            guard idx < cells.count else { return .null }
            return cells[idx]
        }

        public func int(_ idx: Int) -> Int64? { self[idx].int64 }
        public func double(_ idx: Int) -> Double? { self[idx].double }
        public func string(_ idx: Int) -> String? { self[idx].string }
        public func data(_ idx: Int) -> Data? { self[idx].data }
    }
}
