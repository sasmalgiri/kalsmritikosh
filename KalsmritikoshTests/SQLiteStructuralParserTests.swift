//
//  SQLiteStructuralParserTests.swift
//  KalsmritikoshTests
//
//  PAR-009 — the read-only SQLite adapter enumerates user tables and emits a header +
//  one row block per row, each citable by db / table / key (primary key when present).
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("SQLite table adapter (PAR-009)")
struct SQLiteStructuralParserTests {

    /// Build a real plain (non-WAL) SQLite file via the C API and return its bytes.
    /// Closing the handle flushes everything to the single main file (default DELETE
    /// journal), so `Data(contentsOf:)` sees all the rows.
    private func sampleDBData() throws -> Data {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("par9-\(UUID().uuidString).sqlite")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "INSERT INTO people (id, name) VALUES (1,'Alice'),(2,'Bob');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        return try Data(contentsOf: url)
    }

    @Test("Extension + magic bytes route to .sqlite")
    func routing() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.sqlite")) == .sqlite)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.db")) == .sqlite)
        #expect(SourceType.sniffMagicBytes(Data("SQLite format 3\u{0}".utf8)) == .sqlite)
    }

    @Test("Tables and rows become citable blocks (row cites table + key)")
    func rowsCiteTableAndKey() async throws {
        let data = try sampleDBData()
        let doc = try await SQLiteStructuralParser().parse(
            data: data, filename: "people.sqlite", type: .sqlite,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        // One table header + two rows.
        #expect(doc.blocks.contains { $0.kind == .table && $0.rawText.contains("people") })
        let rowBlocks = doc.blocks.filter { $0.kind == .tableRow }
        #expect(rowBlocks.count == 2)

        let alice = try #require(rowBlocks.first { $0.rawText.contains("name=Alice") })
        // Cites db / table / key.
        #expect(alice.locator.sectionPath?.first == "people.sqlite")
        #expect(alice.locator.sectionPath?.contains("people") == true)
        #expect(alice.locator.sectionPath?.last == "id=1")   // primary key value
        #expect(alice.attributes["table"]?.value == .string("people"))
    }
}
