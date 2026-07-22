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
    public nonisolated var parserVersion: String { "1" }

    /// Max rows read per table (citation adapter, not a bulk exporter).
    public nonisolated static let rowCapPerTable = 1000

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

        func add(_ kind: EvidenceBlockKind, _ raw: String, table: String, key: String?) {
            var attrs: [String: AnyCodable] = ["table": AnyCodable(.string(table))]
            if let key { attrs["rowKey"] = AnyCodable(.string(key)) }
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
                let rows = (try? db.query("SELECT * FROM \(quoted) LIMIT \(Self.rowCapPerTable);")) ?? []
                add(.table, "Table \"\(table)\": \(rows.count) row(s), \(columns.count) column(s)",
                    table: table, key: nil)
                for (i, row) in rows.enumerated() {
                    let pairs = zip(columns, row.cells).map { "\($0)=\(Self.render($1))" }
                    let keyValue: String = pkCols.isEmpty
                        ? "row \(i + 1)"
                        : pkCols.compactMap { col in
                            columns.firstIndex(of: col).flatMap { idx in
                                idx < row.cells.count ? "\(col)=\(Self.render(row.cells[idx]))" : nil
                            }
                        }.joined(separator: ", ")
                    add(.tableRow, pairs.joined(separator: " | "), table: table, key: keyValue)
                }
                if rows.count >= Self.rowCapPerTable {
                    warnings.append(ParserWarning(severity: .warning, code: "sqlite.row_cap",
                        message: "Table \(table) exceeded the \(Self.rowCapPerTable)-row citation cap; later rows not indexed."))
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
