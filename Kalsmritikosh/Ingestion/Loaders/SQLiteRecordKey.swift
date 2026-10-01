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
//  F04 — `Walk` is the ONE table traversal both use, resumable from a `Cursor`:
//    • rowid tables: keyset on an unshadowed rowid alias (`alias > last`), first page unbounded
//      so rowids ≤ 0 are read;
//    • WITHOUT ROWID tables: keyset on the primary key as a row value, `(k1, k2, …) > (?, ?, …)`
//      ORDER BY k1, k2, … — SQLite compares each column under its declared collation in BOTH the
//      comparison and the ORDER BY, so the walk and the cursor agree. The key columns are NOT NULL
//      by definition in a WITHOUT ROWID table, so no row is skipped by a NULL comparison. The
//      cursor serializes each key value with its storage class (integer / real / text / blob).
//    • a rowid table whose three aliases are ALL shadowed by user columns: LIMIT/OFFSET in
//      declared-key order. Offsets are stable because a walk only ever resumes over the exact
//      acquired bytes it started on (the cursor belongs to one immutable source version).
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
        /// three aliases shadowed) → page by key or position in `orderBy` order.
        let rowIDAlias: String?
        /// " ORDER BY <pk columns>" for key/positional paging ("" when the table declares no key).
        let orderBy: String
        /// F04 — the quoted primary-key columns of a WITHOUT ROWID table, walked by keyset. Empty
        /// for rowid tables and for a rowid table with every alias shadowed (walked by position).
        let keyColumns: [String]
    }

    /// F04/F05 — `info` is `PRAGMA table_info(<table>)`. A user column literally named "rowid"
    /// hijacks that name, so the first unshadowed alias is used; a probe query tells a WITHOUT
    /// ROWID table apart.
    static func plan(db: ExternalSQLiteSource, quotedTable: String, info: [ExternalSQLiteSource.Row]) -> Plan {
        let columns = Set(info.compactMap { $0.cells.count > 1 ? $0.cells[1].string?.lowercased() : nil })
        var alias = ["rowid", "_rowid_", "oid"].first { !columns.contains($0) }
        var withoutRowID = false
        if let a = alias, (try? db.query("SELECT \(a) FROM \(quotedTable) LIMIT 1;")) == nil { alias = nil; withoutRowID = true }
        let pk = info.compactMap { r -> (Int64, String)? in
            guard r.cells.count > 5, let name = r.cells[1].string,
                  let pos = r.cells[5].int64, pos > 0 else { return nil }
            return (pos, "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return Plan(rowIDAlias: alias, orderBy: pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", "),
                    keyColumns: withoutRowID ? pk : [])
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

    // MARK: - F04 continuation

    /// One key value with its SQLite storage class, so a resumed comparison binds the same type.
    enum KeyValue: Codable, Equatable, Sendable {
        case int(Int64), real(Double), text(String), blob(Data), null

        init(_ cell: ExternalSQLiteSource.Cell) {
            switch cell {
            case .int(let v): self = .int(v)
            case .double(let d): self = .real(d)
            case .text(let s): self = .text(s)
            case .blob(let b): self = .blob(b)
            case .null: self = .null
            }
        }

        var bind: ExternalSQLiteSource.Bind {
            switch self {
            case .int(let v): return .int64(v)
            case .real(let d): return .double(d)
            case .text(let s): return .text(s)
            case .blob(let b): return .blob(b)
            case .null: return .null
            }
        }
    }

    /// Where a table walk stands. `offset` = rows of the table already walked (the position of the
    /// next row). Only meaningful for the exact acquired bytes it was taken from.
    struct Cursor: Codable, Equatable, Sendable {
        var rowID: Int64? = nil
        var key: [KeyValue]? = nil
        var offset: Int = 0

        static let start = Cursor()

        func serialized() -> String {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        static func parse(_ s: String?) -> Cursor? {
            guard let s, let data = s.data(using: .utf8) else { return nil }
            let dec = JSONDecoder()
            dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            return try? dec.decode(Cursor.self, from: data)
        }
    }

    /// One walked row: its record key, its user-column cells and its display key.
    struct WalkedRow {
        let recordKey: String
        let position: Int
        let cells: [ExternalSQLiteSource.Cell]
        /// "pk=value, …" when the table declares a key, else "row <n>" (1-based).
        let keyLabel: String
    }

    /// F04 — the ONE resumable traversal of a table (loader and structural parser both use it).
    struct Walk {
        let db: ExternalSQLiteSource
        let table: String
        let quoted: String
        let columns: [String]
        let plan: Plan
        private let pkNames: [String]

        init?(db: ExternalSQLiteSource, table: String) {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let info = (try? db.query("PRAGMA table_info(\(quoted));")) ?? []
            let columns = info.compactMap { $0.cells.count > 1 ? $0.cells[1].string : nil }
            guard !columns.isEmpty else { return nil }
            self.db = db; self.table = table; self.quoted = quoted; self.columns = columns
            self.plan = SQLiteRecordKey.plan(db: db, quotedTable: quoted, info: info)
            self.pkNames = info.compactMap { r -> (Int64, String)? in
                guard r.cells.count > 5, let name = r.cells[1].string, let pos = r.cells[5].int64, pos > 0 else { return nil }
                return (pos, name)
            }.sorted { $0.0 < $1.0 }.map(\.1)
        }

        func count() throws -> Int {
            Int(try db.query("SELECT COUNT(*) FROM \(quoted);").first?.cells.first?.int64 ?? 0)
        }

        /// Up to `limit` rows strictly after `cursor`, and the cursor after them. Throws on a read
        /// error — a failed page is never mistaken for the end of the table.
        func page(after cursor: Cursor, limit: Int) throws -> (rows: [WalkedRow], next: Cursor) {
            let raw: [ExternalSQLiteSource.Row]
            if let alias = plan.rowIDAlias {
                if let after = cursor.rowID {
                    raw = try db.query("SELECT \(alias), * FROM \(quoted) WHERE \(alias) > ? ORDER BY \(alias) LIMIT ?;",
                                       binds: [.int64(after), .int(limit)])
                } else {
                    raw = try db.query("SELECT \(alias), * FROM \(quoted) ORDER BY \(alias) LIMIT ?;", binds: [.int(limit)])
                }
            } else if !plan.keyColumns.isEmpty {
                let keys = plan.keyColumns.joined(separator: ", ")
                if let after = cursor.key, after.count == plan.keyColumns.count {
                    let marks = after.map { _ in "?" }.joined(separator: ", ")
                    raw = try db.query("SELECT * FROM \(quoted) WHERE (\(keys)) > (\(marks)) ORDER BY \(keys) LIMIT ?;",
                                       binds: after.map(\.bind) + [.int(limit)])
                } else {
                    raw = try db.query("SELECT * FROM \(quoted) ORDER BY \(keys) LIMIT ?;", binds: [.int(limit)])
                }
            } else {
                raw = try db.query("SELECT * FROM \(quoted)\(plan.orderBy) LIMIT ? OFFSET ?;",
                                   binds: [.int(limit), .int(cursor.offset)])
            }
            var next = cursor
            var rows: [WalkedRow] = []
            rows.reserveCapacity(raw.count)
            let keyIndexes = pkNames.compactMap { columns.firstIndex(of: $0) }
            for (i, r) in raw.enumerated() {
                var cells = r.cells
                let position = cursor.offset + i
                let recordKey: String
                if plan.rowIDAlias != nil, let first = cells.first {
                    let id = first.int64 ?? 0
                    recordKey = SQLiteRecordKey.key(table: table, rowID: id)
                    next.rowID = id
                    cells = Array(cells.dropFirst())
                } else {
                    recordKey = SQLiteRecordKey.key(table: table, position: position)
                    if !plan.keyColumns.isEmpty {
                        next.key = keyIndexes.map { $0 < cells.count ? KeyValue(cells[$0]) : .null }
                    }
                }
                let label = pkNames.isEmpty
                    ? "row \(position + 1)"
                    : pkNames.compactMap { col in
                        columns.firstIndex(of: col).flatMap { idx in idx < cells.count ? "\(col)=\(render(cells[idx]))" : nil }
                    }.joined(separator: ", ")
                rows.append(WalkedRow(recordKey: recordKey, position: position, cells: cells, keyLabel: label))
            }
            next.offset = cursor.offset + raw.count
            return (rows, next)
        }

        // MARK: Evidence (identical from the loader and the structural parser)

        /// Ordinals are sparse and stable: table `i` owns `[i << 32, (i + 1) << 32)`; its header is the
        /// first, row `p` is `1 + p`. A resumed walk therefore places a row exactly where a single run would.
        static func headerOrdinal(tableIndex: Int) -> Int { tableIndex << 32 }
        static func rowOrdinal(tableIndex: Int, position: Int) -> Int { (tableIndex << 32) + 1 + position }

        func headerEvidence(dbName: String, tableIndex: Int, rowCount: Int) -> StreamedEvidence {
            StreamedEvidence(identity: "\(table)\u{1F}table", ordinal: Self.headerOrdinal(tableIndex: tableIndex), kind: .table,
                             rawText: "Table \"\(table)\": \(rowCount) row(s), \(columns.count) column(s)",
                             locator: SourceLocator(sectionPath: [dbName, table]),
                             attributes: ["table": AnyCodable(.string(table))])
        }

        func rowEvidence(_ row: WalkedRow, dbName: String, tableIndex: Int) -> StreamedEvidence {
            let pairs = zip(columns, row.cells).map { "\($0)=\(render($1))" }
            return StreamedEvidence(
                identity: row.recordKey, ordinal: Self.rowOrdinal(tableIndex: tableIndex, position: row.position), kind: .tableRow,
                rawText: pairs.joined(separator: " | "),
                locator: SourceLocator(sectionPath: [dbName, table, row.keyLabel]),
                attributes: ["table": AnyCodable(.string(table)), "rowKey": AnyCodable(.string(row.keyLabel)),
                             SQLiteRecordKey.attributeKey: AnyCodable(.string(row.recordKey))])
        }
    }

    /// Cell rendering shared by the searchable text and the citable blocks.
    static func render(_ cell: ExternalSQLiteSource.Cell) -> String {
        switch cell {
        case .int(let v): return String(v)
        case .double(let d): return String(d)
        case .text(let s): return s
        case .blob(let data): return "<blob \(data.count) bytes>"
        case .null: return "NULL"
        }
    }
}
