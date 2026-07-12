//
//  EventSourceBlockLinkTests.swift
//  KalsmritikoshTests
//
//  A5.3 — RuleEventExtractor.attachSourceBlocks: events link to the specific
//  structural block(s) whose text contains the rule marker they fired on, so an
//  event carries event-specific source provenance (not the whole document). Add
//  to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EventSourceBlockLinkTests {

    private func block(_ text: String) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: 0, kind: .paragraph, rawText: text)
    }

    private func event(summary: String?) -> Event {
        Event(kind: .invoiceIssued, date: Date(timeIntervalSince1970: 0),
              title: "Invoice issued", summary: summary, sourceObjectID: UUID())
    }

    @Test func eventLinksToMatchingBlock() {
        let hit = block("The invoice issued on 3 March for services rendered.")
        let miss = block("Unrelated meeting notes.")
        let linked = RuleEventExtractor.attachSourceBlocks(
            to: [event(summary: "invoice issued")], blocks: [miss, hit]
        )
        guard case .array(let ids)? = linked.first?.attributes["sourceBlockIDs"]?.value else {
            Issue.record("no sourceBlockIDs attached"); return
        }
        #expect(ids.count == 1)
        if case .string(let idStr) = ids.first {
            #expect(idStr == hit.id.uuidString)
        } else {
            Issue.record("id not a string")
        }
    }

    @Test func noBlocksLeavesEventsUnchanged() {
        let e = event(summary: "invoice issued")
        let out = RuleEventExtractor.attachSourceBlocks(to: [e], blocks: [])
        #expect(out.first?.attributes["sourceBlockIDs"] == nil)
    }

    @Test func noMarkerMatchAttachesNothing() {
        let out = RuleEventExtractor.attachSourceBlocks(
            to: [event(summary: "invoice issued")],
            blocks: [block("nothing relevant here")]
        )
        #expect(out.first?.attributes["sourceBlockIDs"] == nil)
    }

    @Test func nilSummaryIsSkipped() {
        let out = RuleEventExtractor.attachSourceBlocks(
            to: [event(summary: nil)], blocks: [block("invoice issued today")]
        )
        #expect(out.first?.attributes["sourceBlockIDs"] == nil)
    }
}
