//
//  HistoryReconciliationTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 6 (HIST-035/042/044). Duplicates never count as
//  independent corroboration; typed gaps identify decisive missing evidence;
//  reconciliation folds contradictions + gaps deterministically without collapsing
//  conflicts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 6 — reconciliation")
struct HistoryReconciliationTests {

    private let subjectID = UUID()
    private var subject: HistorySubject { .person(subjectID) }
    private var resolved: ResolvedHistorySubject {
        ResolvedHistorySubject(subject: subject, displayName: "S", canonicalEntityID: subjectID, resolutionConfidence: 1.0)
    }

    private func item(_ title: String, kind: HistoryItemKind, start: Date?, end: Date?) -> HistoryItem {
        HistoryItem(
            subject: subject, kind: kind, title: title,
            start: start.map { TemporalValue(start: $0, precision: .day, confidence: 0.8) },
            end: end.map { TemporalValue(start: $0, end: $0, precision: .day, confidence: 0.8) },
            evidenceStatus: .sourceAsserted, confidence: 0.8,
            evidence: [EvidenceReference(objectID: UUID())])
    }
    private func outline(_ items: [HistoryItem]) -> HistoryOutline {
        HistoryOutline(subject: resolved, corpusSnapshotID: nil, items: items, chapters: [], actors: [],
                       relationships: [],
                       coverage: HistoryCoverage(totalItems: items.count, datedItems: 0, undatedItems: 0,
                                                 earliest: nil, latest: nil, evidenceObjectCount: 0,
                                                 assertionCount: 0, genericFactCount: 0, eventCount: 0))
    }

    @Test("Duplicate copies collapse — corroboration counts distinct sources, not copies")
    func independence() {
        let g = SourceIndependenceGrouper()
        let a = UUID(), b = UUID(), c = UUID()
        // a and b are copies of one source (same content hash); c is independent.
        let keys: [UUID: String] = [a: "hash1", b: "hash1", c: "hash2"]
        #expect(g.independentCount(objectIDs: [a, b, c], keys: keys) == 2)
        #expect(g.isCorroborated(objectIDs: [a, b], keys: [a: "hash1", b: "hash1"]) == false)  // 2 copies = 1 source
        #expect(g.isCorroborated(objectIDs: [a, c], keys: keys) == true)                        // 2 distinct sources
        #expect(g.independentCount(objectIDs: [a], keys: [:]) == 1)                             // no key = independent
    }

    @Test("Typed gaps: missing end date, missing start date, silent period")
    func typedGaps() {
        let start2004 = Date(timeIntervalSince1970: 1_072_915_200)
        let start2010 = Date(timeIntervalSince1970: 1_262_304_000)  // ~6y later → silent period
        let openPeriod = item("Worked at Orchid", kind: .stateStart, start: start2004, end: nil)
        let endOnly = item("Left the role", kind: .stateEnd, start: nil, end: start2010)
        let laterEvent = item("Joined a new firm", kind: .event, start: start2010, end: nil)
        let engine = HistoryGapEngine()
        // openPeriod(2004) → laterEvent(2010) is a >2y silent period between dated items.
        let gaps = engine.infer(outline: outline([openPeriod, endOnly, laterEvent]))
        let kinds = Set(gaps.map(\.kind))
        #expect(kinds.contains(.missingEndDate))     // openPeriod has start, no end
        #expect(kinds.contains(.missingStartDate))   // endOnly has end, no start
        #expect(kinds.contains(.silentPeriod))       // 2004 → 2010 gap
        // Every gap suggests evidence types (actionable, non-accusatory).
        #expect(gaps.allSatisfy { !$0.expectedEvidenceTypes.isEmpty })
    }

    @Test("Reconcile folds gaps deterministically without merging conflicts")
    func reconcileDeterministic() {
        let m = HistoryMaterial(
            subject: resolved,
            provenance: MaterialProvenance(canonicalEntityID: subjectID, eventCount: 0, assertionCount: 0,
                                           genericFactCount: 0, relationshipCount: 0, unscopedSubject: false))
        let o = outline([item("Worked at Orchid", kind: .stateStart, start: Date(timeIntervalSince1970: 1_072_915_200), end: nil)])
        let engine = HistoryReconciliationEngine()
        let r1 = engine.reconcile(outline: o, material: m)
        let r2 = engine.reconcile(outline: o, material: m)
        #expect(!r1.gaps.isEmpty)                                  // the open period → missing end date
        #expect(r1.gaps.map(\.kind) == r2.gaps.map(\.kind))        // deterministic
        #expect(r1.items.count == o.items.count)                  // items untouched (no merging)
    }
}
