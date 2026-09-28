//
//  SQLiteStructuralParser.swift
//  Kalsmritikosh
//
//  PAR-009 — read-only structural adapter for a generic SQLite database. Enumerates
//  user tables and emits one `.table` header block per table plus one `.tableRow` block
//  per row, so a row can be cited by db / table / key (§ "Rows cite DB/table/key"). Opens
//  the file READ-ONLY on a private copy (via ExternalSQLiteSource) — never touches the
//  original, never writes. Bounded row cap keeps a huge DB from exploding the block set.
//
//  Deterministic, offline. Never throws for empty/unreadable input — sets extractionStatus.
//

import Foundation
import CryptoKit

public struct SQLiteStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.sqlite] }
    public nonisolated var parserName: String { "sqlite" }
    /// "2" — F05: rows walked in the loader's order and stamped with a shared record key.
    public nonisolated var parserVersion: String { "2" }

    /// Max rows given an individually-citable block, per table. This parser is the
    /// CITATION layer, not the indexing layer: SQLiteLoader emits every row as
    /// searchable records (DB-1), so a table beyond this cap is fully ingested even
    /// though only its leading rows get a precise per-row locator. Raised from 1000
    /// because 1000 rows of a message store is not a usable citation set either.
    public nonisolated static let rowCapPerTable = 5000

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dbName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, table: String, key: String?, recordKey: String? = nil) {
            var attrs: [String: AnyCodable] = ["table": AnyCodable(.string(table))]
            if let key { attrs["rowKey"] = AnyCodable(.string(key)) }
            if let recordKey { attrs[SQLiteRecordKey.attributeKey] = AnyCodable(.string(recordKey)) }
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: key == nil ? [dbName, table] : [dbName, table, key!]),
                attributes: attrs))
        }

        // Write the bytes to a temp file so ExternalSQLiteSource can open a read-only copy.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-sqlite-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp, options: .atomic)
            let db = try ExternalSQLiteSource(originalPath: tmp)

            let tableRows = try db.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
            let tables = tableRows.compactMap { $0.cells.first?.string }
            if tables.isEmpty {
                warnings.append(ParserWarning(severity: .warning, code: "sqlite.no_tables",
                                              message: "Database has no user tables."))
            }
            for table in tables {
                let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                // Column names + primary-key columns.
                let info = (try? db.query("PRAGMA table_info(\(quoted));")) ?? []
                let columns = info.compactMap { $0.cells.count > 1 ? $0.cells[1].string : nil }
                let pkCols: [String] = info.compactMap { r in
                    guard r.cells.count > 5, let name = r.cells[1].string,
                          (r.cells[5].int64 ?? 0) > 0 else { return nil }
                    return name
                }
                // F05 — walk rows in the SAME order as SQLiteLoader and stamp the same record key, so
                // each loader page object links to exactly its own row blocks.
                let plan = SQLiteRecordKey.plan(db: db, quotedTable: quoted, info: info)
                let rows: [ExternalSQLiteSource.Row]
                if let alias = plan.rowIDAlias {
                    rows = (try? db.query("SELECT \(alias), * FROM \(quoted) ORDER BY \(alias) LIMIT \(Self.rowCapPerTable);")) ?? []
                } else {
                    rows = (try? db.query("SELECT * FROM \(quoted)\(plan.orderBy) LIMIT \(Self.rowCapPerTable);")) ?? []
                }
                add(.table, "Table \"\(table)\": \(rows.count) row(s), \(columns.count) column(s)",
                    table: table, key: nil)
                for (i, fullRow) in rows.enumerated() {
                    var cells = fullRow.cells
                    let recordKey: String?
                    if plan.rowIDAlias != nil, let first = cells.first {
                        recordKey = first.int64.map { SQLiteRecordKey.key(table: table, rowID: $0) }
                        cells = Array(cells.dropFirst())
                    } else {
                        recordKey = SQLiteRecordKey.key(table: table, position: i)
                    }
                    let row = ExternalSQLiteSource.Row(cells: cells)
                    let pairs = zip(columns, row.cells).map { "\($0)=\(Self.render($1))" }
                    let keyValue: String = pkCols.isEmpty
                        ? "row \(i + 1)"
                        : pkCols.compactMap { col in
                            columns.firstIndex(of: col).flatMap { idx in
                                idx < row.cells.count ? "\(col)=\(Self.render(row.cells[idx]))" : nil
                            }
                        }.joined(separator: ", ")
                    add(.tableRow, pairs.joined(separator: " | "), table: table, key: keyValue, recordKey: recordKey)
                }
                if rows.count >= Self.rowCapPerTable {
                    // State the REAL total. "Exceeded the cap" alone leaves an examiner
                    // unable to tell a 5001-row table from a 500 000-row one.
                    let total = (try? db.query("SELECT COUNT(*) FROM \(quoted);"))?
                        .first?.cells.first?.int64
                    let of = total.map { " of \($0)" } ?? ""
                    warnings.append(ParserWarning(severity: .warning, code: "sqlite.row_cap",
                        message: "Table \(table): the first \(Self.rowCapPerTable)\(of) rows have "
                               + "individual citations. All rows remain searchable via record-level "
                               + "ingest; later rows have table-level citations only."))
                }
            }
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "sqlite.unreadable", message: "\(error)"))
        }

        let status: ExtractionStatus = blocks.isEmpty
            ? (warnings.contains { $0.severity == .error } ? .corrupt : .empty)
            : (warnings.isEmpty ? .complete : .partial)
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .sqlite, mimeType: "application/vnd.sqlite3",
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
    }

    /// Render a cell for a citation row (text/number as-is, blobs by size, null explicit).
    private nonisolated static func render(_ cell: ExternalSQLiteSource.Cell) -> String {
        switch cell {
        case .int(let v): return String(v)
        case .double(let d): return String(d)
        case .text(let s): return s
        case .blob(let data): return "<blob \(data.count) bytes>"
        case .null: return "NULL"
        }
    }
}
