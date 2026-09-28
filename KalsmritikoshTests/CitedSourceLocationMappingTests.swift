//
//  CitedSourceLocationMappingTests.swift
//  KalsmritikoshTests
//
//  G2/Stage-3 (AT-19) — the pure mapper from a rich SourceLocator to the exact
//  CitedSourceLocation the viewer opens at. Priority + column-letter parsing +
//  the "no positional anchor → nil" contract (resolver then uses whole-doc).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G2 source-locator → cited location mapping")
struct CitedSourceLocationMappingTests {

    @Test func characterRangeWins() {
        let loc = SourceLocator(characterRange: 10..<42, page: 3)
        #expect(CitedSourceLocation.from(loc) == .charRange(start: 10, end: 42))
    }

    @Test func pageWhenNoCharRange() {
        let loc = SourceLocator(page: 7)
        #expect(CitedSourceLocation.from(loc) == .page(7))
    }

    @Test func tableCellWithColumnLetter() {
        var loc = SourceLocator()
        loc.row = 2; loc.column = "B"
        #expect(CitedSourceLocation.from(loc) == .cell(row: 2, col: 2))
    }

    @Test func rowWithoutColumnDefaultsToZero() {
        var loc = SourceLocator()
        loc.row = 5
        #expect(CitedSourceLocation.from(loc) == .cell(row: 5, col: 0))
    }

    @Test func emailMessageID() {
        var loc = SourceLocator()
        loc.messageID = "msg-42"
        #expect(CitedSourceLocation.from(loc) == .message(id: "msg-42"))
    }

    @Test func noPositionalAnchorIsNil() {
        // A bare locator (only a self-referential block id) has no exact spot.
        var loc = SourceLocator()
        loc.evidenceBlockID = UUID()
        #expect(CitedSourceLocation.from(loc) == nil)
    }

    @Test func columnLetterParsing() {
        #expect(CitedSourceLocation.columnIndex("A") == 1)
        #expect(CitedSourceLocation.columnIndex("Z") == 26)
        #expect(CitedSourceLocation.columnIndex("AA") == 27)
        #expect(CitedSourceLocation.columnIndex("") == nil)
        #expect(CitedSourceLocation.columnIndex("3") == nil)
    }
}
