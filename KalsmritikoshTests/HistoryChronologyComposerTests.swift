//
//  HistoryChronologyComposerTests.swift
//  Kalsmritikosh Tests
//
//  Persona-v2 §7.4 (Phase 12 foundation). The chronology composer produces an
//  evidence-cited, precision-honest, chronologically-ordered section from the
//  outline — undated rows sort last, every row is source-cited (the persona
//  work-product citation gate), deterministic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Persona §7.4 — chronology section composer")
struct HistoryChronologyComposerTests {

    private let subjectID = UUID()

    private func item(_ title: String, start: Date?, precision: DatePrecision = .day) -> HistoryItem {
        HistoryItem(subject: .person(subjectID), kind: .event, title: title,
                    start: start.map { TemporalValue(start: $0, precision: precision, confidence: 0.8) },
                    evidenceStatus: .sourceAsserted, confidence: 0.8,
                    evidence: [EvidenceReference(objectID: UUID())])
    }

    @Test("Chronology is ordered, precision-honest, undated-last, and fully cited")
    func compose() {
        let y2006 = item("Invoice paid", start: Date(timeIntervalSince1970: 1_136_073_600), precision: .day)
        let y2004 = item("MSA signed", start: Date(timeIntervalSince1970: 1_072_915_200), precision: .year)
        let undated = item("Became Director", start: nil)
        let outline = HistoryOutline(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "S",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            corpusSnapshotID: nil, items: [y2006, y2004, undated], chapters: [], actors: [], relationships: [],
            coverage: HistoryCoverage(totalItems: 3, datedItems: 2, undatedItems: 1, earliest: nil, latest: nil,
                                      evidenceObjectCount: 3, assertionCount: 0, genericFactCount: 0, eventCount: 3))

        let section = HistoryChronologyComposer().compose(outline: outline)
        #expect(section.rows.count == 3)
        // Chronological: 2004 before 2006, undated last.
        #expect(section.rows.map(\.title) == ["MSA signed", "Invoice paid", "Became Director"])
        #expect(section.rows[0].datePhrase == "In 2004")            // year precision honoured
        #expect(section.rows[1].datePhrase == "On 2006-01-01")      // day precision
        #expect(section.rows[2].isUndated)                          // undated last
        #expect(section.everyRowCited)                              // citation gate
    }
}
