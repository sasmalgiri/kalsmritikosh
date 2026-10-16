//
//  SnapshotLedger.swift
//  KalsmritikoshViewer
//
//  W4-6 — read-only access to the ledger copy inside a verified snapshot: documents,
//  their passages, full-text search over passages, and the snapshot file holding each
//  document's original (kalsnapshot-sources.json: file id → name in the snapshot).
//  The database is opened immutable and read-only — the viewer can never change it.
//  It is encrypted with the passphrase chosen when the snapshot was exported (W2-7).
//  Passages replaced by a later run (superseded_by_run) are not shown.
//

import Foundation
import SQLCipher

nonisolated struct SnapshotDocument: Identifiable, Hashable, Sendable {
    let id: String          // knowledge object id
    let fileID: String
    let title: String
    let sourceType: String
    let privileged: Bool
}

nonisolated struct SnapshotPassage: Identifiable, Hashable, Sendable {
    let id: String          // chunk id
    let documentID: String
    let ordinal: Int
    let text: String
    let page: Int?
}

nonisolated final class SnapshotLedger: @unchecked Sendable {
    private var db: OpaquePointer?
    let folder: URL
    private let sources: [String: String]
    private let lock = NSLock()

    enum OpenError: Error, LocalizedError, Equatable {
        case noDatabase, cannotOpen(String), wrongPassphrase
        var errorDescription: String? {
            switch self {
            case .noDatabase: return "The snapshot has no ledger database."
            case .cannotOpen(let m): return "The ledger could not be opened: \(m)"
            case .wrongPassphrase: return "That passphrase does not open this snapshot."
            }
        }
    }

    init(folder: URL, entries: [SnapshotVerifier.Entry], passphrase: String) throws {
        self.folder = folder
        guard let dbEntry = entries.first(where: { $0.kind == "database" }) else { throw OpenError.noDatabase }
        let path = folder.appendingPathComponent(dbEntry.relativePath).path
        var c = URLComponents()
        c.scheme = "file"; c.path = path
        c.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        let uri = c.string ?? path
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenError.cannotOpen(m)
        }
        let quoted = "'" + passphrase.replacingOccurrences(of: "'", with: "''") + "'"
        var probe: OpaquePointer?
        let keyed = sqlite3_exec(db, "PRAGMA key = \(quoted);", nil, nil, nil) == SQLITE_OK
            && sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &probe, nil) == SQLITE_OK
            && sqlite3_step(probe) == SQLITE_ROW
        sqlite3_finalize(probe)
        guard keyed else {
            sqlite3_close(db)
            throw OpenError.wrongPassphrase
        }
        let map = (try? Data(contentsOf: folder.appendingPathComponent(SnapshotVerifier.sourcesName)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        // The Mac writes file ids as UUID strings; match case-insensitively.
        sources = Dictionary(map.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    deinit { sqlite3_close(db) }

    /// The original file inside the snapshot, or nil when the snapshot was exported without it.
    func originalURL(fileID: String) -> URL? {
        guard let name = sources[fileID.uppercased()] else { return nil }
        let u = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func documents(limit: Int = 5000) -> [SnapshotDocument] {
        rows("""
            SELECT ko.id, ko.file_id, f.url, ko.source_type, COALESCE(ko.privileged, 0)
            FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            ORDER BY f.url, ko.created_at LIMIT ?;
            """, [.int(limit)]) { s in
            SnapshotDocument(id: Self.text(s, 0), fileID: Self.text(s, 1), title: Self.title(fromURL: Self.text(s, 2)),
                             sourceType: Self.text(s, 3), privileged: sqlite3_column_int(s, 4) != 0)
        }
    }

    func passages(of documentID: String) -> [SnapshotPassage] {
        rows("""
            SELECT id, object_id, ordinal, text, page_number FROM chunks
            WHERE object_id = ? AND superseded_by_run IS NULL ORDER BY ordinal;
            """, [.text(documentID)], Self.passage)
    }

    /// Full-text search over passages. Each word is matched as typed (quoted for FTS5).
    func search(_ query: String, limit: Int = 200) -> [SnapshotPassage] {
        let fts = Self.ftsQuery(query)
        guard !fts.isEmpty else { return [] }
        return rows("""
            SELECT c.id, c.object_id, c.ordinal, c.text, c.page_number
            FROM chunks_fts JOIN chunks c ON c.rowid = chunks_fts.rowid
            WHERE chunks_fts MATCH ? AND c.superseded_by_run IS NULL
            ORDER BY rank LIMIT ?;
            """, [.text(fts), .int(limit)], Self.passage)
    }

    func document(id: String) -> SnapshotDocument? {
        rows("""
            SELECT ko.id, ko.file_id, f.url, ko.source_type, COALESCE(ko.privileged, 0)
            FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE ko.id = ?;
            """, [.text(id)]) { s in
            SnapshotDocument(id: Self.text(s, 0), fileID: Self.text(s, 1), title: Self.title(fromURL: Self.text(s, 2)),
                             sourceType: Self.text(s, 3), privileged: sqlite3_column_int(s, 4) != 0)
        }.first
    }

    // MARK: - helpers

    static func ftsQuery(_ q: String) -> String {
        q.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    static func title(fromURL s: String) -> String {
        let name = URL(string: s)?.lastPathComponent ?? (s as NSString).lastPathComponent
        return (name.removingPercentEncoding ?? name).isEmpty ? "Untitled" : (name.removingPercentEncoding ?? name)
    }

    private static func passage(_ s: OpaquePointer) -> SnapshotPassage {
        SnapshotPassage(id: text(s, 0), documentID: text(s, 1), ordinal: Int(sqlite3_column_int(s, 2)), text: text(s, 3),
                        page: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 4)))
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private enum Bind { case text(String), int(Int) }

    private func rows<T>(_ sql: String, _ binds: [Bind], _ map: (OpaquePointer) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            switch b {
            case .text(let v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }
}
