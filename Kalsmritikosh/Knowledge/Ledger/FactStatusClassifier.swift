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
        gaps: [GapNode],
        reviews: [UUID: FactReview] = [:]
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

        // T17 — a human-review verdict is authoritative: overlay the latest
        // review per subject on top of the derived classification.
        guard !reviews.isEmpty else { return items }
        return items.map { item in
            guard let review = reviews[item.id] else { return item }
            return Self.applyReview(item, review)
        }
    }

    /// Overlay a review verdict. Accept/correct → proven; reject → unverified
    /// (kept, shown rejected). Reason names the reviewer action.
    static func applyReview(_ item: FactStatusItem, _ review: FactReview) -> FactStatusItem {
        let suffix = review.reason.map { " — \($0)" } ?? "."
        let who = review.reviewer
        // A5.5 — reviewer affirmations become `.humanConfirmed`, NOT `.proven`.
        // A person vouching for a fact is not the same as the fact being
        // structurally proven; the honesty contract keeps them distinct.
        switch review.action {
        case .accept:
            return item.overriding(status: .humanConfirmed, reason: "Accepted by reviewer (\(who))\(suffix)")
        case .correct:
            let corrected = review.newValue.map { " New value: \($0)." } ?? ""
            return item.overriding(status: .humanConfirmed, reason: "Corrected by reviewer (\(who))\(suffix)\(corrected)")
        case .merge:
            return item.overriding(status: .humanConfirmed, reason: "Merged by reviewer (\(who))\(suffix)")
        case .split:
            return item.overriding(status: .humanConfirmed, reason: "Split by reviewer (\(who))\(suffix)")
        case .precisionChange:
            let nv = review.newValue.map { " New value: \($0)." } ?? ""
            return item.overriding(status: .humanConfirmed, reason: "Precision changed by reviewer (\(who))\(suffix)\(nv)")
        case .resolveContradiction:
            return item.overriding(status: .humanConfirmed, reason: "Contradiction resolved by reviewer (\(who))\(suffix)")
        case .markAuthority:
            return item.overriding(status: .humanConfirmed, reason: "Marked authoritative by reviewer (\(who))\(suffix)")
        case .reject:
            return item.overriding(status: .unverified, reason: "Rejected by reviewer (\(who))\(suffix) Kept for the record.")
        case .dismissGap:
            return item.overriding(status: .unverified, reason: "Gap dismissed by reviewer (\(who))\(suffix) Kept for the record.")
        // reopenGap / reverse restore the pre-review state: no overlay applied.
        // (latestBySubject already drops reversed verdicts, so a `.reverse` only
        // reaches here defensively.)
        case .reopenGap, .reverse:
            return item
        }
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

        // Precedence 1 — conflict overlay wins over the stored status.
        if conflictedEvidence.contains(e.sourceObjectID) {
            return FactStatusItem(
                id: e.id, status: .contradicted, title: e.title,
                reason: "This event's source is implicated in a contradiction elsewhere in the ledger.",
                date: e.date, confidence: conf,
                evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
            )
        }

        // T16 — trust the PERSISTED evidentiary status; map §13 → UI status.
        let (status, reason) = Self.map(e.status, dateConfidence: e.dateConfidence)
        return FactStatusItem(
            id: e.id, status: status, title: e.title,
            reason: reason, date: e.date, confidence: conf,
            evidenceObjectIDs: [e.sourceObjectID], sourceKind: .event
        )
    }

    /// Map the persisted 8-state EventStatus onto the 5-state UI FactStatus,
    /// with a specific reason. CONTRADICTED is handled by the overlay above.
    static func map(_ s: EventStatus, dateConfidence: Double) -> (FactStatus, String) {
        switch s {
        case .observed:
            return (.proven, "Directly observed in structured evidence (T1) — not inferred.")
        case .reviewed:
            return (.proven, "Accepted by a human reviewer.")
        case .derived:
            return (.inferred, String(format: "Deterministically derived from evidence (date confidence %.0f%%).", dateConfidence * 100))
        case .asserted:
            return (.inferred, "Asserted by a source — supported, but not independently proven.")
        case .inferred:
            return (.inferred, "Reconstructed from multiple evidence units rather than directly stated.")
        case .unsupported:
            return (.unverified, "No supporting evidence found for this event.")
        case .rejected:
            return (.unverified, "Rejected by a human reviewer (kept for the record).")
        case .contradicted:
            return (.contradicted, "Marked contradicted in the ledger.")
        }
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
