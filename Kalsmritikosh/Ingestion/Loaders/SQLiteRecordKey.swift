//
//  SQLiteRecordKey.swift
//  Kalsmritikosh
//
//  F05 — the parser-native identity of one SQLite row, shared by the record loader (which
//  emits one KnowledgeObject per page of rows) and the structural parser (one citable block
//  per row). Both walk a table with the SAME paging plan and stamp the SAME key, so the
//  generic ownership match in IngestCoordinator links each page object to exactly its own
//  row blocks — no format-specific reconstruction.
//
//  Key: "<table>␟r<rowid>" for rowid tables, "<table>␟@<position>" (0-based, primary-key
//  order) for WITHOUT ROWID tables. The unit separator cannot appear in a rowid or position.
//

import Foundation

enum SQLiteRecordKey {

    /// KnowledgeObject metadata key: a JSON array of the record keys the object's text covers.
    static let metadataKey = "recordKeys"
    /// EvidenceBlock attribute key: the one record key the block cites.
    static let attributeKey = "recordKey"

    static func key(table: String, rowID: Int64) -> String { "\(table)\u{1F}r\(rowID)" }
    static func key(table: String, position: Int) -> String { "\(table)\u{1F}@\(position)" }

    /// How to walk one table in a stable order.
    struct Plan {
        /// A rowid alias the table does NOT shadow with a user column; nil = WITHOUT ROWID (or all
        /// three aliases shadowed) → page by position in `orderBy` order.
        let rowIDAlias: String?
        /// " ORDER BY <pk columns>" for positional paging ("" when the table declares no key).
        let orderBy: String
    }

    /// F04/F05 — `info` is `PRAGMA table_info(<table>)`. A user column literally named "rowid"
    /// hijacks that name, so the first unshadowed alias is used; a probe query tells a WITHOUT
    /// ROWID table apart.
    static func plan(db: ExternalSQLiteSource, quotedTable: String, info: [ExternalSQLiteSource.Row]) -> Plan {
        let columns = Set(info.compactMap { $0.cells.count > 1 ? $0.cells[1].string?.lowercased() : nil })
        var alias = ["rowid", "_rowid_", "oid"].first { !columns.contains($0) }
        if let a = alias, (try? db.query("SELECT \(a) FROM \(quotedTable) LIMIT 1;")) == nil { alias = nil }
        let pk = info.compactMap { r -> (Int64, String)? in
            guard r.cells.count > 5, let name = r.cells[1].string,
                  let pos = r.cells[5].int64, pos > 0 else { return nil }
            return (pos, "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return Plan(rowIDAlias: alias, orderBy: pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", "))
    }

    /// Decode a KnowledgeObject's `recordKeys` metadata (nil when absent / not this contract).
    static func keys(in metadata: [String: AnyCodable]) -> Set<String>? {
        guard case .string(let json)? = metadata[metadataKey]?.value,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(array)
    }

    static func encode(_ keys: [String]) -> String {
        (try? JSONEncoder().encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
