//
//  CSVParserTests.swift
//  KalsmritikoshTests
//
//  A3 — CSVStructuralParser: RFC-4180 tokenizing + structured spreadsheet
//  blocks. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct CSVParserTests {

    @Test func rfc4180QuotingAndNewlines() {
        let csv = "name,note\n\"Smith, J.\",\"line1\nline2\"\n\"He said \"\"hi\"\"\",ok"
        let rows = CSVStructuralParser.parseCSV(csv)
        #expect(rows.count == 3)
        #expect(rows[1] == ["Smith, J.", "line1\nline2"])
        #expect(rows[2] == ["He said \"hi\"", "ok"])
    }

    @Test func structuredBlocksCarryCells() async throws {
        let csv = "id,amount\n1,100\n2,250"
        let doc = try await CSVStructuralParser().parse(
            data: Data(csv.utf8), filename: "invoices.csv", type: .csv,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        // sheet + 3 rows
        #expect(doc.blocks.first?.kind == .spreadsheetSheet)
        let rowBlocks = doc.blocks.filter { $0.kind == .spreadsheetRow }
        #expect(rowBlocks.count == 3)
        // Header row flagged; data row carries its cells.
        #expect(rowBlocks.first?.locator.row == 0)
        let dataRow = rowBlocks.first { $0.locator.row == 2 }
        if case .array(let cells)? = dataRow?.attributes["cells"]?.value {
            #expect(cells.count == 2)
        } else {
            Issue.record("data row cells not persisted as array")
        }
    }

    @Test func emptyCSVIsEmptyStatus() async throws {
        let doc = try await CSVStructuralParser().parse(
            data: Data("\n\n".utf8), filename: "x.csv", type: .csv,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .empty)
    }
}
