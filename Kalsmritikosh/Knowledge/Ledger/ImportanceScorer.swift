//
//  Knowledge/Ledger/ImportanceScorer.swift
//  Kalsmritikosh
//
//  System 2 — Hot/Warm/Cold importance tiering.
//
//  Pure scoring policy: given how an object has been used (citations,
//  query hits, pin, age) it produces a single importance score and maps
//  that to an EnrichmentTier. No database, no I/O — the persistence face
//  is EnrichmentStatusRepository, which feeds these signals in and writes
//  the results back. Keeping the math pure means it's trivially testable
//  and the thresholds can be surfaced verbatim in the UI.
//
//  Signal weights favour real usage: a citation in a shipped answer is
//  worth more than a bare retrieval hit, a pin is a strong human vote,
//  and freshness gives a mild, decaying nudge so new material can warm
//  up before it has accumulated a usage history.
//

import Foundation

public struct ImportanceScorer: Sendable {
    /// Weight per citation in a shipped answer (strongest usage signal).
    public let citationWeight: Double
    /// Weight per retrieval hit.
    public let queryHitWeight: Double
    /// Flat bonus for a user-pinned object.
    public let pinnedBonus: Double
    /// Weight per extracted entity the object carries (structural richness).
    public let entityWeight: Double
    /// Weight per extracted event the object carries (structural richness).
    public let eventWeight: Double
    /// Importance at/above which an object is HOT. Public for UI display.
    public let hotThreshold: Double
    /// Importance at/above which an object is WARM (below hot). Public for UI.
    public let warmThreshold: Double

    public init(
        citationWeight: Double = 3.0,
        queryHitWeight: Double = 1.0,
        pinnedBonus: Double = 10.0,
        entityWeight: Double = 0.25,
        eventWeight: Double = 0.75,
        hotThreshold: Double = 8.0,
        warmThreshold: Double = 3.0
    ) {
        self.citationWeight = citationWeight
        self.queryHitWeight = queryHitWeight
        self.pinnedBonus = pinnedBonus
        self.entityWeight = entityWeight
        self.eventWeight = eventWeight
        self.hotThreshold = hotThreshold
        self.warmThreshold = warmThreshold
    }

    /// Weighted usage sum, a structural-richness term, and a mild decaying
    /// recency boost.
    ///
    /// The structural term (entities + events) is what lets System 2 tier
    /// documents from the ledger's OWN shape — a document dense with
    /// extracted people, dates and events is important on arrival, before
    /// it has ever been cited. Usage signals (citations, pins) then push it
    /// further up. The recency boost adds up to +2 for brand-new objects
    /// and fades to 0 over ~60 days, so freshness never dominates.
    public func score(
        citationCount: Int,
        queryHits: Int,
        pinned: Bool,
        ageDays: Double,
        entityCount: Int = 0,
        eventCount: Int = 0
    ) -> Double {
        var total = 0.0
        total += Double(citationCount) * citationWeight
        total += Double(queryHits) * queryHitWeight
        if pinned { total += pinnedBonus }
        total += Double(entityCount) * entityWeight
        total += Double(eventCount) * eventWeight
        total += max(0, 2.0 - ageDays / 30.0)
        return total
    }

    /// Map an already-computed importance score to a tier.
    public func tier(forImportance importance: Double) -> EnrichmentTier {
        if importance >= hotThreshold { return .hot }
        if importance >= warmThreshold { return .warm }
        return .cold
    }

    /// Convenience: score the raw signals and map straight to a tier.
    public func tier(citationCount: Int, queryHits: Int, pinned: Bool, ageDays: Double) -> EnrichmentTier {
        let importance = score(
            citationCount: citationCount,
            queryHits: queryHits,
            pinned: pinned,
            ageDays: ageDays
        )
        return tier(forImportance: importance)
    }
}
