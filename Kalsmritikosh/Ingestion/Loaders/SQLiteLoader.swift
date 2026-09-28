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

public struct SQLiteLoader: StreamingIngestor {
    /// `.knowledgeC` rides the same generic row reader: every row stays indexed
    /// and searchable, while KnowledgeCStructuralParser adds the dated-event
    /// layer on top. Neither type is feature-gated, so both may be claimed
    /// unconditionally (unlike `.chatExport` — see DISC-6).
    public let supportedTypes: Set<SourceType> = [.sqlite, .knowledgeC, .extractionManifest]
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
        var objects: [KnowledgeObject] = []
        try await streamRecords(fileAt: url, type: type,
                                budget: StreamBatchBudget(maxObjects: .max, maxContentBytes: .max)) {
            objects.append(contentsOf: $0)
        }
        return objects
    }

    /// F01 — every page streams: a page is built, handed to `emit`, and dropped.
    public func streamsRecords(type: SourceType) -> Bool { supportedTypes.contains(type) }

    public func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                              emit: ([KnowledgeObject]) async throws -> Void) async throws {
        let db: ExternalSQLiteSource
        do { db = try ExternalSQLiteSource(originalPath: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let dbName = url.lastPathComponent
        let tableRows = try? db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        let tables = (tableRows ?? []).compactMap { $0.cells.first?.string }
        guard !tables.isEmpty else { throw IngestorError.empty(url) }

        var batcher = KnowledgeObjectBatcher(budget: budget)
        var emittedAny = false
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let info = (try? db.query("PRAGMA table_info(\(quoted));")) ?? []
            let columns = info.compactMap { $0.cells.count > 1 ? $0.cells[1].string : nil }
            guard !columns.isEmpty else { continue }

            let total = (try? db.query("SELECT COUNT(*) FROM \(quoted);"))?
                .first?.cells.first?.int64 ?? 0
            if total == 0 { continue }

            // Keyset pagination on rowid keeps a large table linear and gives a
            // stable order. F04 — the rowid is addressed through an alias the table
            // does NOT shadow (a user column literally named "rowid" hijacks that
            // name), and the first page has NO lower bound, so rowids ≤ 0 are read.
            // WITHOUT ROWID tables (or all three aliases shadowed) page by
            // LIMIT/OFFSET ordered by the primary key, so pages are stable.
            // F05 — the SAME plan the structural parser walks, so both stamp the same record keys.
            let plan = SQLiteRecordKey.plan(db: db, quotedTable: quoted, info: info)
            let rowIDAlias = plan.rowIDAlias
            let hasRowID = rowIDAlias != nil
            let orderBy = plan.orderBy

            var lastRowID: Int64? = nil
            var offset = 0
            var emitted = 0
            var page = 0
            while emitted < Int(total), emitted < Self.maxRowsPerTable {
                let rows: [ExternalSQLiteSource.Row]
                if let alias = rowIDAlias {
                    if let after = lastRowID {
                        rows = (try? db.query(
                            "SELECT \(alias), * FROM \(quoted) WHERE \(alias) > ? ORDER BY \(alias) LIMIT ?;",
                            binds: [.int64(after), .int(Self.rowsPerObject)])) ?? []
                    } else {
                        rows = (try? db.query(
                            "SELECT \(alias), * FROM \(quoted) ORDER BY \(alias) LIMIT ?;",
                            binds: [.int(Self.rowsPerObject)])) ?? []
                    }
                } else {
                    rows = (try? db.query(
                        "SELECT * FROM \(quoted)\(orderBy) LIMIT ? OFFSET ?;",
                        binds: [.int(Self.rowsPerObject), .int(offset)])) ?? []
                }
                if rows.isEmpty { break }

                var lines: [String] = ["Database \(dbName), table \"\(table)\" "
                                       + "(rows \(emitted + 1)–\(emitted + rows.count) of \(total)):"]
                var recordKeys: [String] = []
                for (i, row) in rows.enumerated() {
                    // With rowid the first cell is the rowid itself; drop it from the
                    // rendered pairs but use it to advance the cursor.
                    var cells = row.cells
                    if hasRowID, let first = cells.first {
                        lastRowID = first.int64 ?? lastRowID
                        if let id = first.int64 { recordKeys.append(SQLiteRecordKey.key(table: table, rowID: id)) }
                        cells = Array(cells.dropFirst())
                    } else if !hasRowID {
                        recordKeys.append(SQLiteRecordKey.key(table: table, position: offset + i))
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
                    "rowsInTable": AnyCodable(.int(total)),
                    // F05 — the rows this object covers, keyed like the structural row blocks.
                    SQLiteRecordKey.metadataKey: AnyCodable(.string(SQLiteRecordKey.encode(recordKeys)))
                ]
                if emitted >= Self.maxRowsPerTable && Int(total) > Self.maxRowsPerTable {
                    meta["rowBudgetReached"] = AnyCodable(.bool(true))
                    meta["rowsDeferred"] = AnyCodable(.int(total - Int64(emitted)))   // F04 — explicit count
                    lines.append("[Row budget of \(Self.maxRowsPerTable) reached for table "
                                 + "\"\(table)\"; \(Int(total) - emitted) later rows not indexed.]")
                }

                emittedAny = true
                if let batch = batcher.add(KnowledgeObject(
                    sourceFile: url, sourceType: type,
                    content: lines.joined(separator: "\n"),
                    metadata: meta, confidence: .high)) {
                    try await emit(batch)
                }
                page += 1
            }
        }
        if let rest = batcher.drain() { try await emit(rest) }
        guard emittedAny else { throw IngestorError.empty(url) }
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
