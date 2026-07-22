//
//  SourceLocatorEvidenceTests.swift
//  KalsmritikoshTests
//
//  EV-002 — SourceLocator carries a lossless evidence-block anchor; round-trips without
//  losing any dimension; old JSON (pre-field) still decodes.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EV-002 SourceLocator evidence anchor")
struct SourceLocatorEvidenceTests {

    @Test("evidenceBlockID round-trips alongside every other dimension")
    func lossless() throws {
        let blk = UUID(), ch = UUID()
        var loc = SourceLocator(evidenceBlockID: blk, chunkID: ch, page: 3, line: 2)
        loc.row = 5; loc.sheet = "Sheet1"; loc.messageID = "m1"
        let back = try JSONDecoder().decode(SourceLocator.self, from: JSONEncoder().encode(loc))
        #expect(back.evidenceBlockID == blk)
        #expect(back.chunkID == ch)
        #expect(back.page == 3 && back.line == 2 && back.row == 5)
        #expect(back.sheet == "Sheet1" && back.messageID == "m1")
    }

    @Test("Old JSON without evidenceBlockID still decodes (backward compatible)")
    func backwardCompatible() throws {
        let json = #"{"chunkID":"\#(UUID().uuidString)","page":2}"#
        let old = try JSONDecoder().decode(SourceLocator.self, from: Data(json.utf8))
        #expect(old.evidenceBlockID == nil)
        #expect(old.page == 2)
    }
}
