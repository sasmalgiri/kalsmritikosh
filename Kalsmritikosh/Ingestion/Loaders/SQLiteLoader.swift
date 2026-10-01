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
//  chunkable text. F04/F05 — for `.sqlite` each page also carries its rows' citable
//  evidence, and a run stops at a work budget with a durable cursor instead of a hard cap.
//
//  Read-only throughout: ExternalSQLiteSource copies the file (and its -wal /
//  -shm sidecars, which is what makes a live chat.db or History readable) before
//  opening. The original bytes are never touched.
//

import Foundation

public struct SQLiteLoader: ResumableStreamingIngestor {
    /// `.knowledgeC` rides the same generic row reader: every row stays indexed
    /// and searchable, while KnowledgeCStructuralParser adds the dated-event
    /// layer on top. Neither type is feature-gated, so both may be claimed
    /// unconditionally (unlike `.chatExport` — see DISC-6).
    public let supportedTypes: Set<SourceType> = [.sqlite, .knowledgeC, .extractionManifest]
    public let primaryLane: ResourceLane = .diskIO

    /// Rows per KnowledgeObject. Small enough that one object stays chunkable,
    /// large enough that a 200k-row table is ~400 objects rather than 200k.
    public nonisolated static let rowsPerObject = 500
    /// Per-table ceiling of the NON-resumable path only (knowledgeC, extraction manifests, direct
    /// `ingestMany`). Reaching it is recorded on the object, never silently. F04 — `.sqlite` ingest
    /// resumes instead: a per-run work budget (`ResumableStreamBudget`) defers rows to a durable
    /// cursor rather than stopping the table.
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
    public nonisolated func streamsRecords(type: SourceType) -> Bool { supportedTypes.contains(type) }

    public func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                              emit: ([KnowledgeObject]) async throws -> Void) async throws {
        // The non-resumable path (knowledgeC, extraction manifests, direct `ingestMany` callers): the
        // SAME walk, bounded per table by `maxRowsPerTable`; reaching it is recorded on the object.
        var batcher = KnowledgeObjectBatcher(budget: budget)
        var emittedAny = false
        let totals = try await walk(fileAt: url, type: type, rowsPerRun: .max, rowsPerTableCap: Self.maxRowsPerTable,
                                    resume: [:]) { record in
            emittedAny = true
            if let batch = batcher.add(record.object) { try await emit(batch) }
            return true
        }
        if let rest = batcher.drain() { try await emit(rest) }
        _ = totals
        guard emittedAny else { throw IngestorError.empty(url) }
    }

    // MARK: - F04 resumable walk

    /// `.sqlite` resumes; knowledgeC / extraction manifests keep the whole-file path (their own
    /// structural parsers consume the rows).
    public nonisolated func resumes(type: SourceType) -> Bool { type == .sqlite }
    public nonisolated var unitNoun: String { "rows" }

    public func streamResumable(fileAt url: URL, type: SourceType, budget: ResumableStreamBudget,
                                resume: [String: String],
                                emit: (ResumableRecord) async throws -> Bool) async throws -> [ResumableScopeTotal] {
        try await walk(fileAt: url, type: type, rowsPerRun: budget.unitsPerRun, rowsPerTableCap: nil,
                       rowsPerRecord: budget.unitsPerRecord, resume: resume, emit: emit)
    }

    /// F04 — walk every user table in name order from its cursor (`resume`: table → serialized
    /// cursor), keyset-paged (see SQLiteRecordKey.Walk), stopping after `rowsPerRun` rows. Every table
    /// is still COUNTED, so rows beyond the budget are reported as deferred, never silently absent.
    /// A read error throws (a failed page is never mistaken for the end of a table).
    private func walk(fileAt url: URL, type: SourceType, rowsPerRun: Int, rowsPerTableCap: Int?,
                      rowsPerRecord: Int = SQLiteLoader.rowsPerObject, resume: [String: String],
                      emit: (ResumableRecord) async throws -> Bool) async throws -> [ResumableScopeTotal] {
        let db: ExternalSQLiteSource
        do { db = try ExternalSQLiteSource(originalPath: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let dbName = url.lastPathComponent
        let tables: [String]
        do {
            tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
                .compactMap { $0.cells.first?.string }
        } catch { throw IngestorError.unreadable(url, underlying: error) }
        guard !tables.isEmpty else { throw IngestorError.empty(url) }

        var totals: [ResumableScopeTotal] = []
        var remaining = rowsPerRun
        var stopped = false
        for (tableIndex, table) in tables.enumerated() {
            guard let walk = SQLiteRecordKey.Walk(db: db, table: table) else { continue }
            let total: Int
            do { total = try walk.count() } catch { throw IngestorError.unreadable(url, underlying: error) }
            totals.append(ResumableScopeTotal(scope: table, scopeIndex: tableIndex, discovered: total))
            if stopped || total == 0 || remaining <= 0 { continue }
            let limit = rowsPerTableCap.map { min($0, total) } ?? total

            var cursor = SQLiteRecordKey.Cursor.parse(resume[table]) ?? .start
            var page = cursor.offset / max(1, rowsPerRecord)
            while cursor.offset < limit, remaining > 0 {
                let want = min(rowsPerRecord, remaining, limit - cursor.offset)
                let (rows, next): ([SQLiteRecordKey.WalkedRow], SQLiteRecordKey.Cursor)
                do { (rows, next) = try walk.page(after: cursor, limit: want) }
                catch { throw IngestorError.parseFailure(url, reason: "table \"\(table)\" at row \(cursor.offset + 1): \(error)") }
                if rows.isEmpty { break }

                var lines: [String] = ["Database \(dbName), table \"\(table)\" "
                                       + "(rows \(cursor.offset + 1)–\(next.offset) of \(total)):"]
                for row in rows {
                    lines.append(zip(walk.columns, row.cells).map { "\($0) = \(SQLiteRecordKey.render($1))" }.joined(separator: " | "))
                }
                var meta: [String: AnyCodable] = [
                    "filename": AnyCodable(.string(dbName)),
                    "loader": AnyCodable(.string("sqlite-records")),
                    "table": AnyCodable(.string(table)),
                    "page": AnyCodable(.int(Int64(page))),
                    "rowsInPage": AnyCodable(.int(Int64(rows.count))),
                    "rowsInTable": AnyCodable(.int(Int64(total))),
                    // F05 — the rows this object covers, keyed like the row evidence blocks.
                    SQLiteRecordKey.metadataKey: AnyCodable(.string(SQLiteRecordKey.encode(rows.map(\.recordKey))))
                ]
                if let cap = rowsPerTableCap, next.offset >= cap, total > cap {
                    meta["rowBudgetReached"] = AnyCodable(.bool(true))
                    meta["rowsDeferred"] = AnyCodable(.int(Int64(total - next.offset)))   // F04 — explicit count
                    lines.append("[Row budget of \(cap) reached for table \"\(table)\"; \(total - next.offset) later rows not indexed.]")
                }
                let object = KnowledgeObject(sourceFile: url, sourceType: type, content: lines.joined(separator: "\n"),
                                             metadata: meta, confidence: .high)
                let record = ResumableRecord(
                    object: object, scope: table, scopeIndex: tableIndex,
                    position: (tableIndex << 40) + cursor.offset, cursorAfter: next.serialized(), unitsAfter: next.offset,
                    evidence: rows.map { walk.rowEvidence($0, dbName: dbName, tableIndex: tableIndex) },
                    scopeEvidence: cursor.offset == 0 ? [walk.headerEvidence(dbName: dbName, tableIndex: tableIndex, rowCount: total)] : [])
                remaining -= rows.count
                guard try await emit(record) else { stopped = true; break }
                cursor = next
                page += 1
            }
        }
        return totals
    }

}
