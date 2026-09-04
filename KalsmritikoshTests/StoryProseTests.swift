//
//  StoryProseTests.swift
//  Kalsmritikosh Tests
//
//  P4-U3 — summarize-then-place + the grounding gate:
//    · the renderer computes a deterministic gist FIRST and places every unit
//      as a SPAN naming its items (citations survive rephrasing)
//    · the pure grounding gate: same numbers exactly, no new proper nouns —
//      rephrase is wording only, never content
//    · deterministic mode = identical truth content (the gist and sentences
//      carry the same numbers)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4-U3 — summarize-then-place + the grounding gate")
struct StoryProseTests {

    private let subjectID = UUID()

    private func item(_ title: String, day: Int) -> HistoryItem {
        HistoryItem(subject: .person(subjectID), kind: .event, title: title,
                    start: TemporalValue(start: Date(timeIntervalSince1970: TimeInterval(1_704_067_200 + day * 86_400)),
                                         precision: .day, confidence: 0.9),
                    evidenceStatus: .sourceAsserted, confidence: 0.9,
                    evidence: [EvidenceReference(objectID: UUID())])
    }

    @Test("The gist is summarized first and placed as spans that name their items")
    func gistAndSpans() {
        let a = item("Hearing held", day: 0)      // 2024-01-01
        let b = item("Patent granted", day: 40)   // 2024-02-10
        let outline = HistoryOutline(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "P",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            corpusSnapshotID: nil, items: [a, b],
            chapters: [HistoryChapterPlan(ordinal: 0, title: "2024", itemIDs: [a.id, b.id])],
            actors: [], relationships: [],
            coverage: HistoryCoverage(totalItems: 2, datedItems: 2, undatedItems: 0,
                                      earliest: nil, latest: nil, evidenceObjectCount: 2,
                                      assertionCount: 0, genericFactCount: 0, eventCount: 2))

        let rendered = HistoryNarrativeRenderer().render(outline: outline)
        let chapter = rendered.chapters[0]
        #expect(chapter.gist == "2 recorded items, from on 2024-01-01 to on 2024-02-10.")
        let spans = try! #require(chapter.spans)
        #expect(spans.count == 3, "gist span + one span per sentence")
        #expect(spans[0].itemIDs == [a.id, b.id], "the gist stands on the whole chapter")
        #expect(spans[1].itemIDs == [a.id])
        #expect(spans[2].itemIDs == [b.id])
        // The gate's truth contract: gist digits ⊆ chapter truth content.
        let truth = (chapter.gist ?? "") + " " + chapter.prose
        #expect(StoryProseRephraser.digitTokens(chapter.gist ?? "").isSubset(of: StoryProseRephraser.digitTokens(truth)))
        // Deterministic.
        #expect(HistoryNarrativeRenderer().render(outline: outline) == rendered)
    }

    @Test("Grounding gate: same numbers in new wording pass; lost, invented, or new-name prose is rejected")
    func groundingGate() {
        let truth = "2 recorded items, from on 2024-01-01 to on 2024-02-10. " +
                    "On 2024-01-01: Hearing held. On 2024-02-10: Patent granted."
        #expect(StoryProseRephraser.grounded(
            candidate: "The hearing was held on 2024-01-01, and the patent granted on 2024-02-10 — 2 items in all.",
            truth: truth))
        #expect(!StoryProseRephraser.grounded(
            candidate: "The hearing was held on 2024-01-01.", truth: truth),
            "a lost date is a content change, not a rephrase")
        #expect(!StoryProseRephraser.grounded(
            candidate: "The hearing on 2024-01-01 led to the grant on 2024-02-10 of patent 555489, 2 items.",
            truth: truth),
            "an invented number never ships")
        #expect(!StoryProseRephraser.grounded(
            candidate: "Per Khurana, the hearing was on 2024-01-01; the patent granted 2024-02-10 — 2 items.",
            truth: truth),
            "a new proper noun never ships")
    }
}
