//
//  AssertabilityPolicy.swift
//  Kalsmritikosh
//
//  S0.5 item 2, Commit C1. Replaces the single `EvidenceStatus.isAssertable` Boolean with
//  a real policy over the five separated dimensions (EvidenceAssessment) PLUS the evidence
//  shape (exact citations, INDEPENDENT source groups, exact locator, reproducibility). The
//  same policy is consulted by retrieval, MasterBrain answer construction and the export
//  validator, so those three can never disagree about whether a claim may be asserted.
//
//  Core safety rules locked here: human review never manufactures an evidentiary basis
//  (a human-confirmed item whose basis can't be recovered is user-attributed, NEVER a bare
//  fact); duplicates/forwarded copies never fake corroboration (we count INDEPENDENT
//  groups, not raw citations); rejected / missing / unsupported never enter material output;
//  inferences and unresolved conflicts are always labelled. Pure, deterministic, LLM-free.
//

import Foundation

/// Everything the policy needs beyond the assessment: the evidence shape. `independent
/// EvidenceGroupCount` is the number of INDEPENDENT source groups (duplicates and forwarded
/// copies collapse to one) — it must never be substituted by a raw citation count.
public struct AssertabilityContext: Sendable, Hashable {
    public let assessment: EvidenceAssessment
    public let exactEvidenceCount: Int
    public let independentEvidenceGroupCount: Int
    public let hasExactLocator: Bool
    public let hasReproducibleDerivation: Bool

    public nonisolated init(
        assessment: EvidenceAssessment,
        exactEvidenceCount: Int,
        independentEvidenceGroupCount: Int,
        hasExactLocator: Bool,
        hasReproducibleDerivation: Bool = false
    ) {
        self.assessment = assessment
        self.exactEvidenceCount = exactEvidenceCount
        self.independentEvidenceGroupCount = independentEvidenceGroupCount
        self.hasExactLocator = hasExactLocator
        self.hasReproducibleDerivation = hasReproducibleDerivation
    }
}

/// How a claim may be surfaced. Ordered from strongest assertion to refusal.
public enum AssertabilityDecision: String, Sendable, Hashable {
    case assertAsFact
    case assertWithAttribution
    case assertAsCorroborated
    case assertAsDerivation
    case assertWithUserAttribution
    case presentAsInference
    case presentAsConflict
    case refuse

    /// True for the decisions that may appear as a MATERIAL claim in a final answer or
    /// export (with the appropriate framing). `presentAsInference`/`presentAsConflict`
    /// are surfaced but LABELLED; `refuse` is withheld.
    public var isMaterialAssertion: Bool {
        switch self {
        case .assertAsFact, .assertWithAttribution, .assertAsCorroborated,
             .assertAsDerivation, .assertWithUserAttribution:
            return true
        case .presentAsInference, .presentAsConflict, .refuse:
            return false
        }
    }
}

public enum AssertabilityPolicy {

    /// Evaluate in a safety-first priority order. Earlier rules dominate later ones.
    public nonisolated static func evaluate(_ c: AssertabilityContext) -> AssertabilityDecision {
        let a = c.assessment

        // 1. Human rejection is absolute — never in ordinary output (kept in audit).
        if a.review == .rejected { return .refuse }
        // 2. No usable backing evidence.
        if a.availability == .missingEvidence || a.availability == .unsupported { return .refuse }
        // 3. Unresolved / actual conflict is shown as a conflict, never a bare fact.
        if a.conflict == .contradicted || a.conflict == .unresolved { return .presentAsConflict }
        // 4. Inference is always labelled, never silently a fact.
        if a.basis == .inferred { return .presentAsInference }
        // 5. Model proposals not yet human-verified are labelled, never asserted.
        if a.origin == .modelProposed && a.review != .confirmed && a.review != .corrected {
            return .presentAsInference
        }
        // 6. Human confirmation with an unrecoverable basis is USER-attributed — never a
        //    fact. Confirmation is not itself an evidentiary basis.
        if a.review == .confirmed && a.basis == .unknownLegacy { return .assertWithUserAttribution }

        // Any material assertion below needs at least one exact citation.
        guard c.exactEvidenceCount >= 1 else { return .refuse }

        switch a.basis {
        case .directlyObserved:
            // A fact only when it's exactly located; otherwise attribute it.
            return c.hasExactLocator ? .assertAsFact : .assertWithAttribution
        case .sourceAsserted:
            // Corroboration requires ≥2 INDEPENDENT groups (duplicates don't count).
            return c.independentEvidenceGroupCount >= 2 ? .assertAsCorroborated : .assertWithAttribution
        case .deterministicallyDerived:
            // Only a derivation when the inputs reproduce it; else it's an inference.
            return c.hasReproducibleDerivation ? .assertAsDerivation : .presentAsInference
        case .inferred:
            return .presentAsInference          // defensive (handled at rule 4)
        case .unknownLegacy:
            // Unknown basis, not human-confirmed (handled at rule 6): attribute conservatively.
            return .assertWithAttribution
        }
    }
}
