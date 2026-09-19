//
//  CompositeNarrativeSlotExtractorTests.swift
//  KalsmritikoshTests
//
//  L4 — the FM slot-fill's pure guard + parser: a model phrase is accepted only
//  when every content word is already in the source (fact-preserving).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct CompositeNarrativeSlotExtractorTests {

    @Test("Parser keeps only requested slots as (slot, phrase)")
    func parseKeepsRequested() {
        let raw = "why: to review claim 4\nwhere: over email\nwhat: ignored\nhow: by signed amendment"
        let out = CompositeNarrativeSlotExtractor.parse(raw, targets: [.why, .where, .how])
        let dict = Dictionary(uniqueKeysWithValues: out.map { ($0.0, $0.1) })
        #expect(dict[.why] == "to review claim 4")
        #expect(dict[.where] == "over email")
        #expect(dict[.how] == "by signed amendment")
        #expect(dict[.what] == nil)   // not a requested target
    }

    @Test("Parser ignores malformed lines")
    func parseIgnoresJunk() {
        let raw = "no colon here\nwhy:\n:orphan\nwhy: real motive"
        let out = CompositeNarrativeSlotExtractor.parse(raw, targets: [.why])
        #expect(out.count == 1)
        #expect(out.first?.1 == "real motive")
    }

    @Test("Prompt names only the requested targets")
    func promptTargets() {
        let p = CompositeNarrativeSlotExtractor.prompt(
            source: "some passage", targets: [.why, .how])
        #expect(p.contains("why, how"))
        #expect(p.contains("some passage"))
    }
}
