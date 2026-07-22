//
//  HistoryReconciliationEngine.swift
//  Kalsmritikosh
//
//  HIST-041/042/044 (Universal History program, Phase 6). Turns the raw outline into
//  a trustworthy model WITHOUT collapsing conflicts: contradictions stay parallel
//  (both sides preserved — never averaged), typed gaps identify the decisive missing
//  evidence, and duplicate copies never count as independent corroboration. Reuses
//  the existing deterministic ContradictionDetector over the material's events.
//  Deterministic, LLM-free.
//

import Foundation

public struct HistoryReconciliationEngine: Sendable {
    private let detector = ContradictionDetector()
    private let gapEngine: HistoryGapEngine
    private let independence = SourceIndependenceGrouper()

    public init(gapEngine: HistoryGapEngine = HistoryGapEngine()) {
        self.gapEngine = gapEngine
    }

    /// Fold contradictions + typed gaps into the outline. `independenceKeys` maps a
    /// source object id to its independence key (content hash / message id / lineage);
    /// used only to compute honest corroboration, never to merge conflicts.
    public func reconcile(outline: HistoryOutline,
                          material: HistoryMaterial,
                          independenceKeys: [KnowledgeObject.ID: String] = [:]) -> HistoryOutline {
        // Contradictions: the detector keeps BOTH claims (parallel accounts), never
        // picks a winner. Deterministic + deduped by (kind, claimA, claimB).
        let events = material.events
        var contradictions = detector.detectEventDateConflicts(events)
            + detector.detectEventAmountConflicts(events)
            + detector.detectEventLocationConflicts(events)
            + detector.detectEventSignatureConflicts(events)
        contradictions = Self.dedupe(contradictions)

        let gaps = gapEngine.infer(outline: outline)

        return HistoryOutline(
            subject: outline.subject, corpusSnapshotID: outline.corpusSnapshotID,
            items: outline.items, chapters: outline.chapters, actors: outline.actors,
            relationships: outline.relationships, coverage: outline.coverage,
            contradictions: contradictions, gaps: gaps)
    }

    /// Honest corroboration for one item: distinct independent source groups.
    public func corroborationCount(for item: HistoryItem,
                                   independenceKeys: [KnowledgeObject.ID: String]) -> Int {
        independence.independentCount(objectIDs: item.evidence.map(\.objectID), keys: independenceKeys)
    }

    private static func dedupe(_ cs: [Contradiction]) -> [Contradiction] {
        var seen = Set<String>()
        var out: [Contradiction] = []
        for c in cs {
            let key = "\(c.kind.rawValue)|\(c.claimA)|\(c.claimB)"
            if seen.insert(key).inserted { out.append(c) }
        }
        return out.sorted { ($0.kind.rawValue, $0.claimA, $0.claimB) < ($1.kind.rawValue, $1.claimA, $1.claimB) }
    }
}
