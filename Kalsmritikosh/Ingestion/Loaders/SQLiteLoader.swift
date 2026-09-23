//
//  SQLiteLoader.swift
//  Kalsmritikosh
//
//  DB-1 — RECORD-level reader for a SQLite database artifact. Two defects made
//  this necessary, both measured:
//
//  1. No loader owned `.sqlite`, so UniversalParserRegistryBuilder fell back to
//     the structural-only route with TextLoader reading the bytes. TextLoader
//     deliberately throws on binary content, and ExistingParserPluginAdapter
//     turns a loader throw into a whole-plugin failure — so a real database
//     never reached SQLiteStructuralParser at all.
//  2. Even when reached, the structural parser is a CITATION adapter with a
//     1000-row-per-table ceiling. A message store has hundreds of thousands of
//     rows; 1000 of them is not "ingested".
//
//  So this loader returns one KnowledgeObject PER PAGE of rows, the same way
//  EmailLoader returns one per mbox message — the archive's existing mechanism
//  for a file that holds many records. Every row becomes searchable and
//  chunkable text; the structural parser continues to provide precise per-row
//  citations for the leading rows of each table.
//
//  Read-only throughout: ExternalSQLiteSource copies the file (and its -wal /
//  -shm sidecars, which is what makes a live chat.db or History readable) before
//  opening. The original bytes are never touched.
//

import Foundation

public struct SQLiteLoader: Ingestor {
    /// `.knowledgeC` rides the same generic row reader: every row stays indexed
    /// and searchable, while KnowledgeCStructuralParser adds the dated-event
    /// layer on top. Neither type is feature-gated, so both may be claimed
    /// unconditionally (unlike `.chatExport` — see DISC-6).
    public let supportedTypes: Set<SourceType> = [.sqlite, .knowledgeC]
    public let primaryLane: ResourceLane = .diskIO

    /// Rows per KnowledgeObject. Small enough that one object stays chunkable,
    /// large enough that a 200k-row table is ~400 objects rather than 200k.
    public nonisolated static let rowsPerObject = 500
    /// Per-table ceiling. Far above any realistic artifact, but finite so a
    /// corrupt or adversarial database cannot run the ingest forever. Reaching it
    /// is recorded on the object, never silently.
    public nonisolated static let maxRowsPerTable = 500_000

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let objects = try await ingestMany(fileAt: url, type: type)
        guard let first = objects.first else { throw IngestorError.empty(url) }
        return first
    }

    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        let db: ExternalSQLiteSource
        do { db = try ExternalSQLiteSource(originalPath: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let dbName = url.lastPathComponent
        let tableRows = try? db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        let tables = (tableRows ?? []).compactMap { $0.cells.first?.string }
        guard !tables.isEmpty else { throw IngestorError.empty(url) }

        var objects: [KnowledgeObject] = []
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let info = (try? db.query("PRAGMA table_info(\(quoted));")) ?? []
            let columns = info.compactMap { $0.cells.count > 1 ? $0.cells[1].string : nil }
            guard !columns.isEmpty else { continue }

            let total = (try? db.query("SELECT COUNT(*) FROM \(quoted);"))?
                .first?.cells.first?.int64 ?? 0
            if total == 0 { continue }

            // Keyset pagination on rowid keeps a large table linear and gives a
            // stable order. WITHOUT ROWID tables have no rowid, so those fall back
            // to LIMIT/OFFSET — correct, just slower.
            var hasRowID = true
            if (try? db.query("SELECT rowid FROM \(quoted) LIMIT 1;")) == nil { hasRowID = false }

            var lastRowID: Int64 = 0
            var offset = 0
            var emitted = 0
            var page = 0
            while emitted < Int(total), emitted < Self.maxRowsPerTable {
                let rows: [ExternalSQLiteSource.Row]
                if hasRowID {
                    rows = (try? db.query(
                        "SELECT rowid, * FROM \(quoted) WHERE rowid > ? ORDER BY rowid LIMIT ?;",
                        binds: [.int64(lastRowID), .int(Self.rowsPerObject)])) ?? []
                } else {
                    rows = (try? db.query(
                        "SELECT * FROM \(quoted) LIMIT ? OFFSET ?;",
                        binds: [.int(Self.rowsPerObject), .int(offset)])) ?? []
                }
                if rows.isEmpty { break }

                var lines: [String] = ["Database \(dbName), table \"\(table)\" "
                                       + "(rows \(emitted + 1)–\(emitted + rows.count) of \(total)):"]
                for row in rows {
                    // With rowid the first cell is the rowid itself; drop it from the
                    // rendered pairs but use it to advance the cursor.
                    var cells = row.cells
                    if hasRowID, let first = cells.first {
                        lastRowID = first.int64 ?? lastRowID
                        cells = Array(cells.dropFirst())
                    }
                    let pairs = zip(columns, cells)
                        .map { "\($0) = \(Self.render($1))" }
                        .joined(separator: " | ")
                    lines.append(pairs)
                }
                emitted += rows.count
                offset += rows.count

                var meta: [String: AnyCodable] = [
                    "filename": AnyCodable(.string(dbName)),
                    "loader": AnyCodable(.string("sqlite-records")),
                    "table": AnyCodable(.string(table)),
                    "page": AnyCodable(.int(Int64(page))),
                    "rowsInPage": AnyCodable(.int(Int64(rows.count))),
                    "rowsInTable": AnyCodable(.int(total))
                ]
                if emitted >= Self.maxRowsPerTable && Int(total) > Self.maxRowsPerTable {
                    meta["rowBudgetReached"] = AnyCodable(.bool(true))
                    lines.append("[Row budget of \(Self.maxRowsPerTable) reached for table "
                                 + "\"\(table)\"; \(Int(total) - emitted) later rows not indexed.]")
                }

                objects.append(KnowledgeObject(
                    sourceFile: url, sourceType: type,
                    content: lines.joined(separator: "\n"),
                    metadata: meta, confidence: .high))
                page += 1
            }
        }

        guard !objects.isEmpty else { throw IngestorError.empty(url) }
        return objects
    }

    /// Cell rendering. Matches SQLiteStructuralParser so the searchable text and
    /// the citable blocks describe a value the same way.
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
