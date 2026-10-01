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
    /// "3" — F04: the shared resumable walk (keyset on composite keys), stable sparse ordinals, real row totals.
    public nonisolated var parserVersion: String { "3" }
    /// F01 — bounded by design: copies the bytes to a temp file, reads through SQLite, and caps rows per table.
    public nonisolated var boundedMemory: Bool { true }

    /// Max rows this WHOLE-FILE parse gives a block, per table. F04 — ingest no longer relies on it:
    /// the resumable SQLiteLoader walk emits every processed row's block with its record. This bound
    /// applies to re-parse / reprocessing, and a re-parse that would drop rows the ledger already
    /// cites is refused (SourceReprocessingCoordinator.activationRefusal).
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

        func add(_ e: StreamedEvidence) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: e.ordinal, kind: e.kind,
                rawText: e.rawText, locator: e.locator, attributes: e.attributes))
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
            for (tableIndex, table) in tables.enumerated() {
                // F04/F05 — the SAME walk, record keys, ordinals and block text as SQLiteLoader's
                // resumable ingest, so this bounded re-parse and the ingested evidence agree block for block.
                guard let walk = SQLiteRecordKey.Walk(db: db, table: table) else { continue }
                let total = try walk.count()
                add(walk.headerEvidence(dbName: dbName, tableIndex: tableIndex, rowCount: total))
                var cursor = SQLiteRecordKey.Cursor.start
                while cursor.offset < min(total, Self.rowCapPerTable) {
                    let (rows, next) = try walk.page(after: cursor, limit: min(SQLiteLoader.rowsPerObject, Self.rowCapPerTable - cursor.offset))
                    if rows.isEmpty { break }
                    for row in rows { add(walk.rowEvidence(row, dbName: dbName, tableIndex: tableIndex)) }
                    cursor = next
                }
                if total > cursor.offset {
                    // State the REAL total. This whole-file parse (re-parse / reprocessing only) is bounded;
                    // the ingest walk cites every row it has processed and resumes the rest.
                    warnings.append(ParserWarning(severity: .warning, code: "sqlite.row_cap",
                        message: "Table \(table): this bounded parse cites the first \(cursor.offset) of \(total) rows; "
                               + "the resumable ingest cites every row it has processed."))
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
}
