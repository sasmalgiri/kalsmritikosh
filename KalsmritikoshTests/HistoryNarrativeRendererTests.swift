//
//  HistoryNarrativeRendererTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 8 (HIST-052). Deterministic rule-based prose
//  over the outline: every chapter rendered, date phrasing honours precision (a
//  year is never widened to a day), undated items are labelled, gaps surface, and
//  the same outline renders identically. This is the fallback that keeps history
//  from ever dropping to generic RAG.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 8 — deterministic narrative rendering")
struct HistoryNarrativeRendererTests {

    private let subjectID = UUID()

    private func item(_ title: String, start: Date?, precision: DatePrecision) -> HistoryItem {
        HistoryItem(subject: .person(subjectID), kind: .event, title: title,
                    start: start.map { TemporalValue(start: $0, precision: precision, confidence: 0.8) },
                    evidenceStatus: .sourceAsserted, confidence: 0.8,
                    evidence: [EvidenceReference(objectID: UUID())])
    }

    @Test("Renders every chapter with precision-honest, undated-aware, deterministic prose")
    func renders() {
        let dated = item("MSA signed", start: Date(timeIntervalSince1970: 1_072_915_200), precision: .day) // 2004-01-01
        let yearOnly = item("Founded EcoSanskriti", start: Date(timeIntervalSince1970: 1_104_537_600), precision: .year) // 2005
        let undated = item("Became Director", start: nil, precision: .unknown)

        let outline = HistoryOutline(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "Shirshendu",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            corpusSnapshotID: nil, items: [dated, yearOnly, undated],
            chapters: [
                HistoryChapterPlan(ordinal: 0, title: "2004", itemIDs: [dated.id]),
                HistoryChapterPlan(ordinal: 1, title: "2005", itemIDs: [yearOnly.id]),
                HistoryChapterPlan(ordinal: 2, title: "Undated material", itemIDs: [undated.id]),
            ],
            actors: [subjectID], relationships: [],
            coverage: HistoryCoverage(totalItems: 3, datedItems: 2, undatedItems: 1,
                                      earliest: Date(timeIntervalSince1970: 1_072_915_200),
                                      latest: Date(timeIntervalSince1970: 1_104_537_600),
                                      evidenceObjectCount: 3, assertionCount: 0, genericFactCount: 0, eventCount: 2),
            gaps: [HistoryGap(kind: .missingEndDate, subject: .person(subjectID),
                              description: "No end date for the Director role.", confidence: 0.7)])

        let r = HistoryNarrativeRenderer().render(outline: outline)
        #expect(r.chapters.count == 3)
        #expect(r.chapters[0].prose == "On 2004-01-01: MSA signed.")   // day precision → full date
        #expect(r.chapters[1].prose == "In 2005: Founded EcoSanskriti.") // year precision → "In 2005"
        #expect(r.chapters[2].prose == "Became Director (date not established).") // undated labelled
        #expect(r.summary.contains("Shirshendu"))
        #expect(r.gapsNote != nil)                                     // gaps surfaced
        // Deterministic.
        #expect(HistoryNarrativeRenderer().render(outline: outline) == r)
    }
}
