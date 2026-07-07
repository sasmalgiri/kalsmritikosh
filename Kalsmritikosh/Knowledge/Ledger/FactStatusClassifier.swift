//
//  FactStatusClassifier.swift
//  Kalsmritikosh
//
//  System — Fact Status Matrix (T14). Turns the structured ledger the app
//  already maintains (events, assertions, contradictions, gaps) into a flat
//  list of FactStatusItems, each labelled Proven / Inferred / Contradicted /
//  Missing / Unverified with a specific reason.
//
//  Discipline (same as GapDetector): PURE and DETERMINISTIC. No database, no
//  I/O, no LLM, no capability calls, and it writes NOTHING to the ledger. It
//  reads signals that already exist on each record — qualityTier, confidence,
//  dateConfidence, agent, evidence links — and derives a status from them.
//  The classification is an interpretation of the ledger, never a new fact.
//

import Foundation

public struct FactStatusClassifier: Sendable {

    // MARK: Thresholds (named, with justification)

    /// An event/assertion at or above this confidence is eligible to be
    /// "Proven" (paired with structured provenance). 0.75 ≈ high band.
    static let provenConfidenceFloor: Double = 0.75
    /// Below this, a claim is too weak to stand on its own → Unverified.
    /// Matches Confidence.low (0.33): the app's existing trust floor.
    static let unverifiedCeiling: Double = 0.33
    /// An event whose DATE we don't trust this much is treated as derived
    /// rather than observed, even if its content confidence is decent.
    static let inferredDateConfidenceCeiling: Double = 0.60

    /// Agents whose assertions are structured/authoritative (vs. LLM-inferred).
    /// A user-entered or ontology-derived assertion with real evidence is a
    /// directly-asserted fact; an LLM assertion is an inference.
    static let authoritativeAgents: Set<String> = ["user", "system.ontology"]

    public init() {}

    // MARK: Entry point

    /// Classify the whole working set into status items. Order within the
    /// returned array is: contradictions, then events, then assertions, then
    /// gaps — callers sort/filter per tab.
    public func classify(
        events: [Event],
        assertions: [Assertion],
        contradictions: [Contradiction],
        gaps: [GapNode]
    ) -> [FactStatusItem] {
        var items: [FactStatusItem] = []

        // KnowledgeObject IDs implicated on either side of a contradiction.
        // An event or assertion whose evidence lands here is shown as
        // contradicted, not proven — conflict takes precedence.
        let conflictedEvidence: Set<UUID> = contradictions.reduce(into: []) { set, c in
            if let a = c.evidenceA { set.insert(a) }
            if let b = c.evidenceB { set.insert(b) }
        }

        items.append(contentsOf: contradictions.map(classifyContradiction))
        items.append(contentsOf: events.map { classifyEvent($0, conflictedEvidence: conflictedEvidence) })
        items.append(contentsOf: assertions.compactMap { classifyAssertion($0, conflictedEvidence: conflictedEvidence) })
        items.append(contentsOf: gaps.map(classifyGap))

        return items
    }

    // MARK: Per-kind rules

    private func classifyContradiction(_ c: Contradiction) -> FactStatusItem {
        let evidence = [c.evidenceA, c.evidenceB].compactMap { $0 }
        return FactStatusItem(
            id: c.id,
            status: .contradicted,
            title: c.description.isEmpty ? c.claimA : c.description,
            reason: "Conflicts with a second source; both claims are preserved and not reconciled automatically.",
            date: c.detectedAt,
            confidence: severityConfidence(c.severity),
            evidenceObjectIDs: evidence,
            sourceKind: .contradiction,
            secondaryText: c.claimB
        )
    }

    private func classifyEvent(_ e: Event, conflictedEvidence: Set<UUID>) -> FactStatusItem {
        let conf = e.confidence.value

        // Precedence 1 — conflict.
        if conflictedEvidence.contains(e.sourceObjectID) {
            return FactStatusItem(
                id: e.id, status: .contradicted, title: e.title,
                reason: "This event's source is implicated in a contradiction elsewhere in the ledger.",
                date: e.date, confidence: conf,
                evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
            )
        }

        // Precedence 2 — too weak to trust.
        if conf < Self.unverifiedCeiling {
            return FactStatusItem(
                id: e.id, status: .unverified, title: e.title,
                reason: String(format: "Event confidence is low (%.0f%%) with no corroboration.", conf * 100),
                date: e.date, confidence: conf,
                evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
            )
        }

        // Precedence 3 — directly observed structured fact.
        if e.qualityTier == .t1 && conf >= Self.provenConfidenceFloor
            && e.dateConfidence >= Self.inferredDateConfidenceCeiling {
            return FactStatusItem(
                id: e.id, status: .proven, title: e.title,
                reason: "Structured T1 evidence with a high-confidence date — directly observed, not inferred.",
                date: e.date, confidence: conf,
                evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
            )
        }

        // Otherwise — reconstructed/derived. Name the specific weak signal.
        let why: String
        if e.dateConfidence < Self.inferredDateConfidenceCeiling {
            why = String(format: "Date is derived, not directly stated (date confidence %.0f%%).", e.dateConfidence * 100)
        } else if e.kind == .other {
            why = "Event type could not be pinned down at extraction; reconstructed from context."
        } else if e.qualityTier == .t3 {
            why = "Extracted from low-tier (T3) evidence; treated as an inference."
        } else {
            why = "Reconstructed from evidence rather than directly asserted by a single authoritative source."
        }
        return FactStatusItem(
            id: e.id, status: .inferred, title: e.title,
            reason: why, date: e.date, confidence: conf,
            evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
        )
    }

    /// Retracted assertions are history, not current facts — omitted from the
    /// active matrix (the ledger still keeps them; nothing is deleted).
    private func classifyAssertion(_ a: Assertion, conflictedEvidence: Set<UUID>) -> FactStatusItem? {
        if a.isRetracted { return nil }

        let title = "\(a.predicate.replacingOccurrences(of: "_", with: " ")) — \(objectLabel(a.object))"

        // Precedence 1 — conflict.
        if a.evidenceObjectIDs.contains(where: conflictedEvidence.contains) {
            return FactStatusItem(
                id: a.id, status: .contradicted, title: title,
                reason: "An evidence source for this assertion is implicated in a contradiction.",
                date: a.recordedAt, confidence: a.confidence,
                evidenceObjectIDs: a.evidenceObjectIDs, sourceKind: .assertion
            )
        }

        // Precedence 2 — no evidence backs it.
        if a.evidenceObjectIDs.isEmpty {
            return FactStatusItem(
                id: a.id, status: .unverified, title: title,
                reason: "Asserted with no supporting evidence attached.",
                date: a.recordedAt, confidence: a.confidence,
                evidenceObjectIDs: [], sourceKind: .assertion
            )
        }

        // Precedence 3 — very low confidence.
        if a.confidence < Self.unverifiedCeiling {
            return FactStatusItem(
                id: a.id, status: .unverified, title: title,
                reason: String(format: "Assertion confidence is low (%.0f%%).", a.confidence * 100),
                date: a.recordedAt, confidence: a.confidence,
                evidenceObjectIDs: a.evidenceObjectIDs, sourceKind: .assertion
            )
        }

        // Authoritative + evidenced + confident → directly asserted fact.
        if Self.authoritativeAgents.contains(a.agent) && a.confidence >= Self.provenConfidenceFloor {
            return FactStatusItem(
                id: a.id, status: .proven, title: title,
                reason: "Asserted by an authoritative source (\(a.agent)) with attached evidence.",
                date: a.recordedAt, confidence: a.confidence,
                evidenceObjectIDs: a.evidenceObjectIDs, sourceKind: .assertion
            )
        }

        // Everything else (incl. LLM-extracted) is an inference.
        return FactStatusItem(
            id: a.id, status: .inferred, title: title,
            reason: "Extracted by \(a.agent); a supported inference rather than a directly observed fact.",
            date: a.recordedAt, confidence: a.confidence,
            evidenceObjectIDs: a.evidenceObjectIDs, sourceKind: .assertion
        )
    }

    private func classifyGap(_ g: GapNode) -> FactStatusItem {
        FactStatusItem(
            id: g.id, status: .missing, title: g.description,
            reason: g.reason,
            date: g.detectedAt, confidence: g.confidence,
            evidenceObjectIDs: [g.evidenceObjectID].compactMap { $0 },
            sourceKind: .gap
        )
    }

    // MARK: Helpers

    private func severityConfidence(_ s: Contradiction.Severity) -> Double {
        switch s {
        case .high:   return 0.9
        case .medium: return 0.6
        case .low:    return 0.35
        }
    }

    private func objectLabel(_ o: Assertion.Object) -> String {
        switch o {
        case .entity:            return "(entity)"
        case .event:             return "(event)"
        case .literal(let s):    return s
        }
    }
}
