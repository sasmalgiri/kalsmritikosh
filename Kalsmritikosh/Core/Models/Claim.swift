//
//  Claim.swift
//  Kalsmritikosh
//
//  PA-009 (persona-v2 Stage 1 foundation). The ONE canonical, persona-NEUTRAL atomic
//  claim that every persona (legal / investigation / journalism / research / individual)
//  points at. This is the core of persona invariance: there is no persona field on a
//  Claim — persona framing lives in the composer / work-product layer, never on the claim.
//
//  A Claim NEVER duplicates source truth. It REFERENCES the ledger's source-truth objects
//  by id — Events, Assertions, GenericFacts, TemporalClaims, Relationships, HistoryItems
//  (via `derivedFrom`) — and carries EXACT evidence pointers (via `evidence`). Its trust
//  classification binds to the canonical five-dimension `EvidenceAssessment` +
//  `AssertabilityPolicy`, never to a forked `EvidenceStatus` enum.
//
//  Distinct from the other "claim-ish" types (all narrower / non-canonical): `ComposedClaim`
//  (export validation), `TemporalClaim` (interval facts), `WorkProductClaim` (rendered
//  output), `NarrativeClaimCitation` (prose grounding). Pure domain model, LLM-free.
//

import Foundation

public struct Claim: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    /// The canonical subject (an `Entity.ID`) this claim is about, when subject-scoped.
    /// `nil` for corpus-level claims not tied to a single subject. Scoping is by subject —
    /// a Claim carries no persona/workspace ownership, so it cannot leak across personas.
    public let subjectID: Entity.ID?
    public let subjectLabel: String
    /// The atomic, persona-NEUTRAL statement. Deliberately no persona field: one claim
    /// serves every persona (§4.2 invariance).
    public let statement: String
    /// Canonical five-dimension trust classification (basis / review / origin /
    /// availability / conflict). Binds to `AssertabilityPolicy` — never a forked enum.
    public let assessment: EvidenceAssessment
    public let confidence: Double
    /// EXACT evidence backing the claim — reuses the unified provenance type shared with
    /// history items, so lineage/evidence are consistent across the ledger.
    public let evidence: [EvidenceReference]
    /// What source-truth objects this claim was derived FROM — referenced by id, never
    /// copied.
    public let derivedFrom: [DerivedReference]
    /// The contradiction group this claim participates in, when it conflicts with others.
    public let contradictionGroupID: UUID?
    public let createdAt: Date

    /// Deprecated compatibility shim — derived from `assessment`, never stored.
    @available(*, deprecated, message: "Use assessment (+ AssertabilityPolicy)")
    public var evidenceStatus: EvidenceStatus { LegacyEvidenceStatusAdapter.encode(assessment) }

    public nonisolated init(
        id: UUID = UUID(), subjectID: Entity.ID? = nil, subjectLabel: String,
        statement: String, assessment: EvidenceAssessment, confidence: Double,
        evidence: [EvidenceReference] = [], derivedFrom: [DerivedReference] = [],
        contradictionGroupID: UUID? = nil, createdAt: Date
    ) {
        self.id = id; self.subjectID = subjectID; self.subjectLabel = subjectLabel
        self.statement = statement; self.assessment = assessment; self.confidence = confidence
        self.evidence = evidence; self.derivedFrom = derivedFrom
        self.contradictionGroupID = contradictionGroupID; self.createdAt = createdAt
    }
}

/// An append-only human review action on a Claim (preserve-not-delete). The latest review
/// determines the claim's current `ReviewDisposition`, which feeds AssertabilityPolicy. The
/// review dimension is human ACTION only — it NEVER sets the evidence basis.
public struct ClaimReview: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let claimID: Claim.ID
    public let disposition: ReviewDisposition
    /// The claim's statement (or corrected value) before / after this review, for corrections.
    public let priorValue: String?
    public let newValue: String?
    public let reviewer: String
    public let reason: String?
    public let reviewedAt: Date

    public nonisolated init(
        id: UUID = UUID(), claimID: Claim.ID, disposition: ReviewDisposition,
        priorValue: String? = nil, newValue: String? = nil,
        reviewer: String, reason: String? = nil, reviewedAt: Date
    ) {
        self.id = id; self.claimID = claimID; self.disposition = disposition
        self.priorValue = priorValue; self.newValue = newValue
        self.reviewer = reviewer; self.reason = reason; self.reviewedAt = reviewedAt
    }
}

/// Where a Claim was USED — an answer, a work product, an export, an investigation. The
/// append-only usage ledger traces which outputs a claim supported so that, when a source
/// changes, the affected outputs are known.
public enum ClaimUsageContext: String, Codable, Sendable, Hashable, CaseIterable {
    case answer
    case workProduct
    case export
    case investigation
}

public struct ClaimUsage: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let claimID: Claim.ID
    public let context: ClaimUsageContext
    /// The output that used the claim (e.g. a work-product-run id), when known.
    public let referenceID: UUID?
    public let note: String?
    public let usedAt: Date

    public nonisolated init(
        id: UUID = UUID(), claimID: Claim.ID, context: ClaimUsageContext,
        referenceID: UUID? = nil, note: String? = nil, usedAt: Date
    ) {
        self.id = id; self.claimID = claimID; self.context = context
        self.referenceID = referenceID; self.note = note; self.usedAt = usedAt
    }
}
