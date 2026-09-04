//
//  GapLeadFinder.swift
//  Kalsmritikosh
//
//  P4-U2 (B-4) — GAP-DRIVEN retrieval: each typed gap already names the
//  evidence that would fill it (the gap engine's expectedEvidenceTypes); this
//  runs those as budgeted archive searches and surfaces LEADS — candidate
//  documents the reviewer can open. The fence:
//
//    · leads are ADVISORY — a lead never closes a gap, never edits the
//      outline, never joins evidence membership; a human does that
//    · budgeted per pass and per gap; an unclosable gap stays HONESTLY OPEN
//      (no lead rows, the gap itself untouched)
//    · deterministic: gaps in their engine order, queries in declared order,
//      candidates deduped + sorted
//
//  The search function is injected (the FTS door), so this stays pure enough
//  to prove in CI and free of retrieval-stack coupling.
//

import Foundation

public struct GapLead: Sendable, Equatable {
    public let gapID: UUID
    public let gapKind: HistoryGapKind
    /// Candidate source documents, deduped, deterministic order.
    public let candidateObjectIDs: [KnowledgeObject.ID]
    /// The queries that produced them (receipt material).
    public let queriesTried: [String]
}

public struct GapLeadFinder: Sendable {
    /// Per-pass and per-gap budgets — leads are a bounded assist, not a crawl.
    public let maxGapsPerPass: Int
    public let maxQueriesPerGap: Int
    public let maxLeadsPerGap: Int

    public init(maxGapsPerPass: Int = 10, maxQueriesPerGap: Int = 3, maxLeadsPerGap: Int = 5) {
        self.maxGapsPerPass = maxGapsPerPass
        self.maxQueriesPerGap = maxQueriesPerGap
        self.maxLeadsPerGap = maxLeadsPerGap
    }

    /// Run one budgeted pass. `search` maps a query to candidate source object
    /// ids (the FTS door). Gaps beyond the pass budget are simply not tried
    /// this pass — reported by the receipt, never silently skipped.
    public func findLeads(
        for gaps: [HistoryGap],
        search: @Sendable (String) async -> [KnowledgeObject.ID]
    ) async -> (leads: [GapLead], gapsTried: Int, gapsDeferred: Int) {
        var leads: [GapLead] = []
        let tried = gaps.prefix(maxGapsPerPass)
        for gap in tried {
            // The gap's own evidence is already known — leads must be NEW.
            let known = Set(gap.inferenceBasis.map(\.objectID))
            var candidates: [KnowledgeObject.ID] = []
            var queries: [String] = []
            for target in gap.expectedEvidenceTypes.prefix(maxQueriesPerGap) {
                queries.append(target)
                let hits = await search(target)
                candidates.append(contentsOf: hits.filter { !known.contains($0) })
            }
            var seen = Set<KnowledgeObject.ID>()
            let unique = candidates.filter { seen.insert($0).inserted }
                .sorted { $0.uuidString < $1.uuidString }
                .prefix(maxLeadsPerGap)
            // No candidates → the gap stays honestly open: no lead is emitted.
            if !unique.isEmpty {
                leads.append(GapLead(gapID: gap.id, gapKind: gap.kind,
                                     candidateObjectIDs: Array(unique), queriesTried: queries))
            }
        }
        return (leads, tried.count, max(0, gaps.count - tried.count))
    }
}
