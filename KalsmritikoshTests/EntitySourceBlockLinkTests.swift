//
//  EntitySourceBlockLinkTests.swift
//  KalsmritikoshTests
//
//  A5.4 — NLEntityExtractor.attachSourceBlocks: an entity links to the block(s)
//  where its mention occurs, preserving mention provenance. Add to the test
//  target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EntitySourceBlockLinkTests {

    private func block(_ text: String) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: 0, kind: .paragraph, rawText: text)
    }

    private func entity(_ value: String, normalized: String? = nil) -> Entity {
        Entity(kind: .person, value: value, normalizedValue: normalized, sourceObjectID: UUID())
    }

    @Test func entityLinksToBlockContainingItsMention() {
        let hit = block("Alice Martin approved the budget on Tuesday.")
        let miss = block("The quarterly report is attached.")
        let linked = NLEntityExtractor.attachSourceBlocks(
            to: [entity("Alice Martin")], blocks: [miss, hit]
        )
        guard case .array(let ids)? = linked.first?.attributes["sourceBlockIDs"]?.value else {
            Issue.record("no sourceBlockIDs attached"); return
        }
        #expect(ids.count == 1)
        if case .string(let idStr) = ids.first { #expect(idStr == hit.id.uuidString) }
    }

    @Test func normalizedValuePreferredForMatching() {
        let hit = block("Contact acme corporation for details.")
        let linked = NLEntityExtractor.attachSourceBlocks(
            to: [entity("ACME Corp.", normalized: "acme corporation")], blocks: [hit]
        )
        #expect(linked.first?.attributes["sourceBlockIDs"] != nil)
    }

    @Test func shortMentionsAreSkipped() {
        // < 3 chars would match too much noise.
        let out = NLEntityExtractor.attachSourceBlocks(
            to: [entity("Al")], blocks: [block("Al and everyone else were there")]
        )
        #expect(out.first?.attributes["sourceBlockIDs"] == nil)
    }

    @Test func noBlocksLeavesEntitiesUnchanged() {
        let out = NLEntityExtractor.attachSourceBlocks(to: [entity("Alice Martin")], blocks: [])
        #expect(out.first?.attributes["sourceBlockIDs"] == nil)
    }
}
