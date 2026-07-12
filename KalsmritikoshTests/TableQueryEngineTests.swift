//
//  TableQueryEngineTests.swift
//  KalsmritikoshTests
//
//  A6.4 — TableQueryEngine answers aggregate/lookup questions deterministically
//  from persisted spreadsheet cells. Blocks are built via CSVStructuralParser so
//  the test proves the engine reads the exact shape the parsers produce. Add to
//  the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct TableQueryEngineTests {

    private func blocks(_ csv: String) async throws -> [EvidenceBlock] {
        try await CSVStructuralParser().parse(
            data: Data(csv.utf8), filename: "sales.csv", type: .csv,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        ).blocks
    }

    @Test func sumOfAColumn() async throws {
        let b = try await blocks("region,amount\nNorth,100\nSouth,250\nEast,150")
        let r = TableQueryEngine().evaluate(.sum, column: "amount", blocks: b)
        #expect(r?.value == 500)
        #expect(r?.rowsConsidered == 3)
    }

    @Test func averageAndExtremes() async throws {
        let b = try await blocks("item,price\nA,10\nB,20\nC,30")
        #expect(TableQueryEngine().evaluate(.average, column: "price", blocks: b)?.value == 20)
        #expect(TableQueryEngine().evaluate(.max, column: "price", blocks: b)?.value == 30)
        #expect(TableQueryEngine().evaluate(.min, column: "price", blocks: b)?.value == 10)
    }

    @Test func countOfRowsExcludesHeader() async throws {
        let b = try await blocks("name,role\nAlice,PM\nBob,Dev")
        #expect(TableQueryEngine().evaluate(.count, column: nil, blocks: b)?.value == 2)
    }

    @Test func currencyAndSeparatorsAreParsed() async throws {
        let b = try await blocks("vendor,cost\nAcme,\"$1,200.50\"\nBeta,\"$800\"")
        #expect(TableQueryEngine().evaluate(.sum, column: "cost", blocks: b)?.value == 2000.50)
    }

    @Test func unknownColumnReturnsNil() async throws {
        let b = try await blocks("a,b\n1,2")
        #expect(TableQueryEngine().evaluate(.sum, column: "nonexistent", blocks: b) == nil)
    }

    @Test func questionParsingMapsToAggregateAndColumn() {
        let engine = TableQueryEngine()
        let headers = ["region", "amount"]
        #expect(engine.parseQuestion("What is the total amount?", headers: headers)?.0 == .sum)
        #expect(engine.parseQuestion("What is the total amount?", headers: headers)?.1 == "amount")
        #expect(engine.parseQuestion("How many rows are there?", headers: headers)?.0 == .count)
        #expect(engine.parseQuestion("Who is the vendor?", headers: headers) == nil)
    }
}
