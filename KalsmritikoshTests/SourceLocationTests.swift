//
//  SourceLocationTests.swift
//  KalsmritikoshTests
//
//  G2/Stage-3 — a citation resolves to an exact location when one exists,
//  and to the honest .wholeDocument fallback otherwise. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G2 source location")
struct SourceLocationTests {

    @Test func exactLocationsResolveAndDescribe() async {
        let cases: [(UUID, CitedSourceLocation)] = [
            (UUID(), .charRange(start: 10, end: 42)),
            (UUID(), .page(3)),
            (UUID(), .cell(row: 2, col: 4)),
            (UUID(), .message(id: "msg-1")),
        ]
        let map = Dictionary(uniqueKeysWithValues: cases)
        let locator = SourceLocationResolver { id in map[id] }
        for (id, expected) in cases {
            let got = await locator.locate(citation: .init(objectID: id, snippet: "x"))
            #expect(got == expected)
        }
        #expect(CitedSourceLocation.describe(.charRange(start: 10, end: 42)) == "characters 10–42")
        #expect(CitedSourceLocation.describe(.page(3)) == "page 3")
        #expect(CitedSourceLocation.describe(.cell(row: 2, col: 4)) == "row 2, col 4")
        #expect(CitedSourceLocation.describe(.message(id: "msg-1")) == "message msg-1")
    }

    @Test func nilInjectionFallsBackToWholeDocument() async {
        let locator = SourceLocationResolver { _ in nil }
        let got = await locator.locate(citation: .init(objectID: UUID(), snippet: "x"))
        #expect(got == .wholeDocument, "no exact location → the honest whole-document fallback")
        #expect(CitedSourceLocation.describe(.wholeDocument) == "whole document")
    }
}
