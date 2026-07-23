//
//  HistoryInnovationsTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 13 (INN-200/201). Evidence Time Machine diffs
//  two reconstructions (new/retracted/changed items + new/resolved gaps); the
//  Missing Chapter Engine turns gaps into persona-framed, evidence-targeted actions
//  without changing the underlying gap. Both deterministic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 13 — innovations (diff + missing chapters)")
struct HistoryInnovationsTests {

    private let subjectID = UUID()

    private func item(_ title: String, kind: HistoryItemKind = .event, status: EvidenceStatus = .sourceAsserted,
                      start: Date? = nil, evidence: Int = 1) -> HistoryItem {
        HistoryItem(subject: .person(subjectID), kind: kind, title: title,
                    start: start.map { TemporalValue(start: $0, precision: .day, confidence: 0.8) },
                    evidenceStatus: status, confidence: 0.8,
                    evidence: (0..<evidence).map { _ in EvidenceReference(objectID: UUID()) })
    }
    private func outline(_ items: [HistoryItem], gaps: [HistoryGap] = []) -> HistoryOutline {
        HistoryOutline(subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "S",
                                                       canonicalEntityID: subjectID, resolutionConfidence: 1.0),
                       corpusSnapshotID: nil, items: items, chapters: [], actors: [], relationships: [],
                       coverage: HistoryCoverage(totalItems: items.count, datedItems: 0, undatedItems: 0,
                                                 earliest: nil, latest: nil, evidenceObjectCount: 0,
                                                 assertionCount: 0, genericFactCount: 0, eventCount: 0),
                       gaps: gaps)
    }
    private func gap(_ kind: HistoryGapKind, _ desc: String) -> HistoryGap {
        HistoryGap(kind: kind, subject: .person(subjectID), description: desc,
                   expectedEvidenceTypes: ["relieving letter", "final salary slip"], confidence: 0.7)
    }

    @Test("Evidence Time Machine: new, retracted, changed items + new/resolved gaps")
    func diff() {
        let stableEvidenceUpgrade = item("MSA signed", status: .sourceAsserted, evidence: 1)
        let old = outline([item("Draft only"), stableEvidenceUpgrade],
                          gaps: [gap(.missingEndDate, "No end date for role.")])
        // new: "Draft only" retracted; "MSA signed" now human-confirmed (status change);
        // "Invoice paid" added; the missing-end-date gap resolved.
        let new = outline([item("MSA signed", status: .humanConfirmed, evidence: 2), item("Invoice paid")],
                          gaps: [])

        let d = HistoryDiffEngine().diff(old: old, new: new)
        #expect(d.newItems.map(\.title) == ["Invoice paid"])
        #expect(d.retractedItems.map(\.title) == ["Draft only"])
        #expect(d.changedItems.count == 1)
        #expect(d.changedItems.first?.after.title == "MSA signed")
        #expect(d.changedItems.first?.changes.contains { $0.contains("status") } == true)
        #expect(d.resolvedGaps.count == 1)
        #expect(d.newGaps.isEmpty)
        #expect(!d.isEmpty)
    }

    @Test("Missing Chapter Engine: persona framing changes, gap + evidence targets do not")
    func missingChapters() {
        let gaps = [gap(.missingEndDate, "No end date for the Orchid role.")]
        let lawyer = MissingChapterEngine().actions(for: gaps, persona: .lawyer)
        let journalist = MissingChapterEngine().actions(for: gaps, persona: .journalist)

        #expect(lawyer.first?.personaLabel == "Missing document request")
        #expect(journalist.first?.personaLabel == "Interview / right-of-reply question")
        // Same underlying gap + evidence targets across personas (facts unchanged).
        #expect(lawyer.first?.id == journalist.first?.id)
        #expect(lawyer.first?.searchTargets == ["relieving letter", "final salary slip"])
        #expect(lawyer.first?.prompt == journalist.first?.prompt)
    }
}
