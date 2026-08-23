//
//  HistoryOutline.swift
//  Kalsmritikosh
//
//  HIST-051 (Universal History program, Phase 5). The COMPLETE deterministic outline
//  built BEFORE any prose. LLM budgets may cap prose generation, but never outline
//  completeness — every collected/projected item appears here. Reconciliation
//  outputs (contradictions/alternatives/gaps) are filled by Phase 6; they default
//  empty so the outline is usable from Phase 5.
//

import Foundation

public struct HistoryChapterPlan: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let ordinal: Int
    public let title: String
    public let subtitle: String?
    public let start: TemporalValue?
    public let end: TemporalValue?
    public let itemIDs: [UUID]
    public nonisolated init(id: UUID = UUID(), ordinal: Int, title: String, subtitle: String? = nil,
                            start: TemporalValue? = nil, end: TemporalValue? = nil, itemIDs: [UUID]) {
        self.id = id; self.ordinal = ordinal; self.title = title; self.subtitle = subtitle
        self.start = start; self.end = end; self.itemIDs = itemIDs
    }
}

/// The completeness picture — shown SEPARATELY (never one vague "92%"). Phase 5
/// computes the temporal/evidence coverage; source-parsing coverage etc. layer on
/// in Phase 6's HistoryCoverageEngine.
public nonisolated struct HistoryCoverage: Sendable, Codable, Hashable {
    public let totalItems: Int
    public let datedItems: Int
    public let undatedItems: Int
    public let earliest: Date?
    public let latest: Date?
    public let evidenceObjectCount: Int
    public let assertionCount: Int
    public let genericFactCount: Int
    public let eventCount: Int
    public nonisolated init(totalItems: Int, datedItems: Int, undatedItems: Int, earliest: Date?,
                            latest: Date?, evidenceObjectCount: Int, assertionCount: Int,
                            genericFactCount: Int, eventCount: Int) {
        self.totalItems = totalItems; self.datedItems = datedItems; self.undatedItems = undatedItems
        self.earliest = earliest; self.latest = latest; self.evidenceObjectCount = evidenceObjectCount
        self.assertionCount = assertionCount; self.genericFactCount = genericFactCount; self.eventCount = eventCount
    }
}

public struct HistoryOutline: Sendable {
    public let subject: ResolvedHistorySubject
    public let corpusSnapshotID: UUID?
    public let items: [HistoryItem]
    public let chapters: [HistoryChapterPlan]
    public let actors: [Entity.ID]
    public let relationships: [Relationship]
    public let coverage: HistoryCoverage
    // Filled by Phase 6 reconciliation; empty in Phase 5.
    public let contradictions: [Contradiction]
    public let gaps: [HistoryGap]

    public nonisolated init(
        subject: ResolvedHistorySubject, corpusSnapshotID: UUID?, items: [HistoryItem],
        chapters: [HistoryChapterPlan], actors: [Entity.ID], relationships: [Relationship],
        coverage: HistoryCoverage, contradictions: [Contradiction] = [], gaps: [HistoryGap] = []
    ) {
        self.subject = subject; self.corpusSnapshotID = corpusSnapshotID; self.items = items
        self.chapters = chapters; self.actors = actors; self.relationships = relationships
        self.coverage = coverage; self.contradictions = contradictions; self.gaps = gaps
    }

    /// Completeness invariant: every item belongs to exactly one chapter.
    public var everyItemChaptered: Bool {
        let chaptered = chapters.flatMap(\.itemIDs)
        return Set(chaptered) == Set(items.map(\.id)) && chaptered.count == items.count
    }
}
