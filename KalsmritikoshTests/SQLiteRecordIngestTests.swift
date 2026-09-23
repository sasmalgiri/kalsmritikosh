//
//  SQLiteRecordIngestTests.swift
//  KalsmritikoshTests
//
//  DB-1 — proves the database lane against a real, large SQLite file.
//
//  Two defects are pinned here so they cannot come back:
//    1. No loader owned `.sqlite`, so the registry fell back to TextLoader, which
//       throws on binary — and ExistingParserPluginAdapter turns a loader throw
//       into a whole-plugin failure. A real database never reached a parser.
//    2. The structural parser is a citation adapter with a per-table row ceiling.
//       On a 5000-row message store that meant most rows were never indexed.
//
//  The fix is record-level ingest: one KnowledgeObject per page of rows, the same
//  mechanism mbox already uses for a file holding many records.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("SQLite record-level ingest (DB-1)")
@MainActor
struct SQLiteRecordIngestTests {

    /// Builds a real database with `count` message rows plus a small second table.
    private func makeDatabase(rows count: Int, in dir: URL, named: String = "msgstore.db") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named)
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }
        #expect(sqlite3_exec(h, "CREATE TABLE messages(id INTEGER PRIMARY KEY, author TEXT, body TEXT);",
                             nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "CREATE TABLE contacts(id INTEGER PRIMARY KEY, handle TEXT);",
                             nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "BEGIN;", nil, nil, nil) == SQLITE_OK)
        for i in 1...count {
            let sql = "INSERT INTO messages(author, body) VALUES('riyaz','message number \(i)');"
            #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(h, "INSERT INTO contacts(handle) VALUES('+919812345678');",
                             nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "COMMIT;", nil, nil, nil) == SQLITE_OK)
        return url
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbprobe-\(UUID().uuidString)")
    }

    // MARK: - The old failure, pinned

    @Test("Reading a database as plain text loses the schema; the record loader keeps it")
    func textRouteLosesStructure() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 5000, in: dir)

        // Measured, and more subtle than "it throws". SQLite stores TEXT values as
        // raw UTF-8, so a text-heavy database decodes far enough to slip past
        // TextLoader's binary guard and the message bodies DO appear in the output.
        // That is the trap: the result looks ingested. What is always missing is the
        // schema — no column is joined to its value, no table is named — so the
        // indexed text cannot answer "who wrote this" or "which table is this from".
        let asText = try? await TextLoader().ingest(fileAt: url, type: .txt)
        if let asText {
            #expect(asText.content.contains("message number 5000"))       // bodies leak through
            #expect(!asText.content.contains("body = message number 5000"))  // but unassociated
            #expect(!asText.content.contains("table \"messages\""))
        }

        let records = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let text = records.map(\.content).joined(separator: "\n")
        #expect(text.contains("body = message number 5000"))
        #expect(text.contains("author = riyaz"))
        #expect(text.contains("table \"messages\""))
    }

    @Test("A blob-heavy database IS rejected by the plain-text route, aborting the plugin")
    func blobHeavyDatabaseThrowsInTextRoute() async throws {
        // The other half of defect 1. Real app databases are full of blobs
        // (attachments, protobuf payloads, attributedBody). Here TextLoader's
        // binary guard fires and throws — and ExistingParserPluginAdapter turns a
        // loader throw into a whole-plugin failure, so the structural parser never
        // ran and the artifact was lost entirely.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blobs.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "CREATE TABLE payloads(id INTEGER PRIMARY KEY, blob BLOB);",
                             nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "BEGIN;", nil, nil, nil) == SQLITE_OK)
        for _ in 1...200 {
            #expect(sqlite3_exec(h, "INSERT INTO payloads(blob) VALUES(randomblob(256));",
                                 nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(h, "COMMIT;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)

        await #expect(throws: (any Error).self) {
            _ = try await TextLoader().ingest(fileAt: url, type: .txt)
        }
        // The record loader reads it and describes the blobs honestly.
        let records = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        #expect(!records.isEmpty)
        #expect(records.map(\.content).joined().contains("blob = <blob 256 bytes>"))
    }

    // MARK: - Record-level ingest

    @Test("Every row of a 5000-row table is ingested, not just the citation cap")
    func allRowsAreIngested() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 5000, in: dir)

        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let text = objects.map(\.content).joined(separator: "\n")

        // The first row, the last row, and a row far beyond the old 1000 cap.
        #expect(text.contains("message number 1"))
        #expect(text.contains("message number 2500"))
        #expect(text.contains("message number 5000"))
        // And the second table is not skipped.
        #expect(text.contains("+919812345678"))

        // Paged, not one giant object: 5000 rows at 500/page = 10 pages, +1 contacts.
        #expect(objects.count == 11)
        for object in objects {
            #expect(object.content.count < 200_000, "a page grew too large to chunk well")
        }
    }

    @Test("No row is duplicated or dropped across page boundaries")
    func paginationIsExact() async throws {
        // Keyset pagination is easy to get wrong by one row in either direction,
        // and in an investigation a duplicated or missing message is a wrong answer.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 1234, in: dir)

        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        // Trailing newline so the final row has a delimiter like every other row —
        // otherwise the last row counts as zero and the test lies about a real pass.
        let text = objects.map(\.content).joined(separator: "\n") + "\n"
        for i in 1...1234 {
            // Require a delimiter after the number so "…number 1" does not match
            // inside "…number 1234".
            let occurrences = text.components(separatedBy: "message number \(i) ").count - 1
                            + text.components(separatedBy: "message number \(i)\n").count - 1
            #expect(occurrences == 1, "row \(i) appears \(occurrences) times, expected once")
        }
    }

    @Test("Each page records which table and row range it came from")
    func pagesCarryProvenance() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 1200, in: dir)

        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let messagePages = objects.filter {
            if case .string(let t)? = $0.metadata["table"]?.value { return t == "messages" }
            return false
        }
        #expect(messagePages.count == 3)
        // Row totals travel with the page, so an answer can say "of 1200".
        for page in messagePages {
            if case .int(let total)? = page.metadata["rowsInTable"]?.value {
                #expect(total == 1200)
            } else {
                Issue.record("page is missing rowsInTable")
            }
            #expect(page.content.hasPrefix("Database msgstore.db, table \"messages\""))
        }
        #expect(messagePages.first?.content.contains("rows 1–500 of 1200") == true)
        #expect(messagePages.last?.content.contains("rows 1001–1200 of 1200") == true)
    }

    @Test("Ingest is deterministic — same database, same objects in the same order")
    func ingestIsDeterministic() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 900, in: dir)
        let first = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite).map(\.content)
        let second = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite).map(\.content)
        #expect(first == second)
    }

    @Test("The original file is never opened for writing")
    func originalIsNeverTouched() async throws {
        // ExternalSQLiteSource copies first. Proof: the modification date and the
        // bytes are identical afterwards, and no -wal/-shm appears beside the original.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 600, in: dir)
        let before = try Data(contentsOf: url)
        let beforeDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        _ = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)

        #expect(try Data(contentsOf: url) == before)
        let afterDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(beforeDate == afterDate)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    // MARK: - Honesty

    @Test("A database with no user tables is empty, not silently successful")
    func emptyDatabaseIsHonest() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blank.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        sqlite3_close(h)

        await #expect(throws: (any Error).self) {
            _ = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        }
    }

    @Test("The citation warning states the real row total, not just 'capped'")
    func capWarningNamesTheTotal() async throws {
        // An examiner must be able to tell a 5001-row table from a 500 000-row one.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeDatabase(rows: 5200, in: dir)
        let doc = try await SQLiteStructuralParser().parse(
            data: try Data(contentsOf: url), filename: "msgstore.db", type: .sqlite,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        let warning = try #require(doc.warnings.first { $0.code == "sqlite.row_cap" })
        #expect(warning.message.contains("of 5200"))
        #expect(warning.message.contains("remain searchable"))
    }

    // MARK: - Wiring

    @Test("The universal registry routes .sqlite to the real record loader")
    func registryUsesTheRecordLoader() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.sqlite)
        #expect(plugin.pluginID == "format.sqlite")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
    }
}
