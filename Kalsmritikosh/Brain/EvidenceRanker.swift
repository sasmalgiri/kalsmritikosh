//
//  EvidenceRanker.swift
//  Kalsmritikosh
//
//  Phase J.14 — Vol 17 §A10. Explainable per-citation ranking along
//  four orthogonal dimensions the reference standard names:
//
//      independence  — how unique is this source vs. the rest of the
//                      citation set? A claim backed by 3 distinct
//                      KO sources ranks higher than 3 citations into
//                      the same KO.
//      corroboration — how many other citations point at the same
//                      event/subject? A claim cited by multiple
//                      chunks of separate KOs ranks high.
//      freshness     — exponential decay over age. Email-archive
//                      half-life of ~3 years; older but still
//                      relevant evidence keeps a meaningful score.
//      provenance    — the source KO's own confidence (set at
//                      ingest). Forensic PDFs ship near 1.0; OCR'd
//                      images ship lower.
//
//  Returns the original citation order alongside a per-citation
//  EvidenceScore so the UI can sort, highlight, or filter without
//  disturbing the caller's existing layout.
//
//  Quality-or-nothing: when none of the metadata is available, every
//  citation gets a neutral 0.5 in every dimension. The ranker never
//  invents a score it can't justify.
//

import Foundation

public struct EvidenceScore: Sendable, Hashable {
    public let independence: Double
    public let corroboration: Double
    public let freshness: Double
    public let provenance: Double

    /// Composite — weighted mean. Weights mirror the design
    /// research's recommendation: independence + corroboration carry
    /// the most signal, freshness fills in, provenance gates floor.
    public var composite: Double {
        let raw =
            0.32 * independence
            + 0.30 * corroboration
            + 0.18 * freshness
            + 0.20 * provenance
        return max(0, min(1, raw))
    }
}

public struct EvidenceRanker: Sendable {
    public init() {}

    /// Freshness half-life in days. After this many days the score
    /// halves; doubles that, quarters, etc. 1095 = ~3 years.
    public static let freshnessHalfLifeDays: Double = 1_095

    /// Compute per-citation scores. `freshnessAnchorDates` carries
    /// the "evidence date" for each citation's eventID (when known)
    /// so the freshness term is anchored on the actual event date,
    /// not the citation row's own createdAt.
    public func rank(
        citations: [VerifiedAnswer.Citation],
        freshnessAnchorDates: [Event.ID: Date] = [:],
        objectConfidence: [KnowledgeObject.ID: Double] = [:],
        now: Date = Date()
    ) -> [EvidenceScore] {
        guard !citations.isEmpty else { return [] }

        // Independence: per-objectID density. Low frequency → high
        // independence.
        var perObjectCount: [KnowledgeObject.ID: Int] = [:]
        for citation in citations {
            perObjectCount[citation.objectID, default: 0] += 1
        }
        let totalCitations = citations.count

        // Corroboration: per-eventID density. Many citations → high
        // corroboration. Citations without an eventID get a neutral
        // 0.5 since they can't claim corroboration.
        var perEventCount: [Event.ID: Int] = [:]
        for citation in citations {
            guard let eid = citation.eventID else { continue }
            perEventCount[eid, default: 0] += 1
        }
        let maxEventCorroboration = perEventCount.values.max() ?? 1

        return citations.map { citation in
            // Independence — uniqueness against the whole set.
            // 1 row of N → 1.0. N rows of N → 1 / N → 0 (clamped at 0.05).
            let dup = Double(perObjectCount[citation.objectID] ?? 1)
            let independenceRaw = 1.0 - (dup - 1.0) / Double(max(1, totalCitations - 1))
            let independence = max(0.05, min(1.0, independenceRaw))

            // Corroboration — how many citations agree on this event.
            // Normalized by the most-corroborated event in the set so
            // a single citation per event still gets 1 / max < 1.
            let corroboration: Double
            if let eid = citation.eventID,
               let count = perEventCount[eid], count > 0 {
                corroboration = min(1.0, Double(count) / Double(maxEventCorroboration))
            } else {
                corroboration = 0.5
            }

            // Freshness — exponential decay over age. When no anchor
            // date is available, fall back to 0.5.
            let freshness: Double
            if let eid = citation.eventID,
               let anchor = freshnessAnchorDates[eid] {
                let ageDays = max(0, now.timeIntervalSince(anchor) / 86_400)
                freshness = pow(0.5, ageDays / Self.freshnessHalfLifeDays)
            } else {
                freshness = 0.5
            }

            // Provenance — the source KO's confidence at ingest.
            let provenance = max(0.05, min(1.0, objectConfidence[citation.objectID] ?? 0.5))

            return EvidenceScore(
                independence: independence,
                corroboration: corroboration,
                freshness: freshness,
                provenance: provenance
            )
        }
    }

    /// Convenience — return the citations sorted DESC by composite
    /// score, paired with their score. Useful when the UI wants to
    /// surface "top 3 most-trusted citations".
    public func ranked(
        citations: [VerifiedAnswer.Citation],
        freshnessAnchorDates: [Event.ID: Date] = [:],
        objectConfidence: [KnowledgeObject.ID: Double] = [:],
        now: Date = Date()
    ) -> [(citation: VerifiedAnswer.Citation, score: EvidenceScore)] {
        let scores = rank(
            citations: citations,
            freshnessAnchorDates: freshnessAnchorDates,
            objectConfidence: objectConfidence,
            now: now
        )
        return Array(zip(citations, scores))
            .sorted { lhs, rhs in
                lhs.1.composite > rhs.1.composite
            }
    }
}
