//
//  CSVRowEndingTests.swift
//  KalsmritikoshTests
//
//  F30 — the same two-row CSV written with CRLF, LF and bare CR (plus a quoted field
//  holding a newline) must give the same rows through EVERY CSV importer.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F30 — CSV row endings")
struct CSVRowEndingTests {

    static let endings: [String] = ["\r\n", "\n", "\r"]

    private static func sample(_ eol: String) -> String {
        "name,note\(eol)Asha,\"line one\(eol)line two\"\(eol)Ravi,\"said \"\"hi\"\"\"\(eol)"
    }

    private static func expected(_ eol: String) -> [[String]] {
        [["name", "note"], ["Asha", "line one\(eol)line two"], ["Ravi", "said \"hi\""]]
    }

    @Test("Structural parser", arguments: endings)
    func structural(eol: String) {
        #expect(CSVStructuralParser.parseCSV(Self.sample(eol)) == Self.expected(eol))
    }

    @Test("Discussion mappers' reader", arguments: endings)
    func discussion(eol: String) {
        #expect(DiscussionCSV.parse(Self.sample(eol)) == Self.expected(eol))
    }

    @Test("Workbench import", arguments: endings)
    func workbench(eol: String) {
        #expect(WorkbenchCSV.parse(Self.sample(eol)) == Self.expected(eol))
    }

    @Test("A CRLF file becomes one row block per record, each citing its own row")
    func structuralBlocksKeepRowLocators() async throws {
        let data = Data("a,b\r\n1,2\r\n3,4\r\n".utf8)
        let doc = try await CSVStructuralParser().parse(
            data: data, filename: "w.csv", type: .csv, logicalSourceID: UUID(), sourceVersionID: UUID())
        let rows = doc.blocks.filter { $0.kind == .spreadsheetRow }
        #expect(rows.map(\.locator.row) == [0, 1, 2])
        #expect(rows.map(\.rawText) == ["a | b", "1 | 2", "3 | 4"])
    }

    @Test("Blank lines keep later row numbers; a BOM never reaches the first header")
    func blankLinesAndBOM() {
        let rows = CSVRowReader.rows("\u{FEFF}h1,h2\r\n\r\nx,y\r\n")
        #expect(rows == [["h1", "h2"], [""], ["x", "y"]])
    }
}
