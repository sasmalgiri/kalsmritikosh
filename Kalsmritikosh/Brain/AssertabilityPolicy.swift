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
public nonisolated struct AssertabilityContext: Sendable, Hashable, Codable {
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
public nonisolated enum AssertabilityDecision: String, Sendable, Hashable, Codable {
    case assertAsFact
    case assertWithAttribution
    case assertAsCorroborated
    case assertAsDerivation
    case assertWithUserAttribution
    case presentAsInference
    case presentAsConflict
    case refuse

    /// May this item appear in output AT ALL? Everything except `refuse` may surface —
    /// inferences and conflicts must remain VISIBLE (with explicit labels), never silently
    /// filtered. Use this for visibility gates, NOT `isAssertiveDecision`.
    public var maySurface: Bool { self != .refuse }

    /// Does this decision ASSERT a material claim (as fact / attributed / corroborated /
    /// derivation / user-attributed)? Inference and conflict are surfaced but NOT asserted.
    /// Use this for assertion gates.
    public var isAssertiveDecision: Bool {
        switch self {
        case .assertAsFact, .assertWithAttribution, .assertAsCorroborated,
             .assertAsDerivation, .assertWithUserAttribution:
            return true
        case .presentAsInference, .presentAsConflict, .refuse:
            return false
        }
    }

    /// Must the surface force an explicit frame (attribution / user-attribution /
    /// inference / conflict label)? A bare fact / corroboration / derivation does not.
    public var requiresExplicitFraming: Bool {
        switch self {
        case .assertWithAttribution, .assertWithUserAttribution,
             .presentAsInference, .presentAsConflict:
            return true
        case .assertAsFact, .assertAsCorroborated, .assertAsDerivation, .refuse:
            return false
        }
    }

    /// Deprecated alias — split into `maySurface` (visibility) and `isAssertiveDecision`
    /// (assertion). Kept briefly so no caller silently changes meaning; do not use for
    /// visibility (it would hide labelled inference/conflict).
    @available(*, deprecated, message: "Use isAssertiveDecision for assertion gates or maySurface for visibility")
    public var isMaterialAssertion: Bool { isAssertiveDecision }
}

public nonisolated enum AssertabilityPolicy {

    /// Evaluate in a safety-first priority order. Earlier rules dominate later ones.
    public nonisolated static func evaluate(_ c: AssertabilityContext) -> AssertabilityDecision {
        let a = c.assessment
        // Sanitise counts: never trust more independent groups than exact citations, and
        // clamp negatives. A malformed "1 citation but 2 groups" must NOT corroborate.
        let exactCount = max(0, c.exactEvidenceCount)
        let independentGroups = min(max(0, c.independentEvidenceGroupCount), exactCount)

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
        // 6. A human workflow action (confirmed OR corrected) over an unrecoverable basis
        //    is USER-attributed — never a bare fact, and only when it still cites evidence.
        //    Confirmation/correction is not itself an evidentiary basis.
        if a.basis == .unknownLegacy, a.review == .confirmed || a.review == .corrected {
            return exactCount >= 1 ? .assertWithUserAttribution : .refuse
        }

        // Any material assertion below needs at least one exact citation.
        guard exactCount >= 1 else { return .refuse }

        switch a.basis {
        case .directlyObserved:
            // A fact only when it's exactly located; otherwise attribute it.
            return c.hasExactLocator ? .assertAsFact : .assertWithAttribution
        case .sourceAsserted:
            // Corroboration requires ≥2 EXACT citations AND ≥2 INDEPENDENT groups
            // (duplicates / forwarded copies collapse to one group and don't count).
            return (exactCount >= 2 && independentGroups >= 2) ? .assertAsCorroborated : .assertWithAttribution
        case .deterministicallyDerived:
            // Only a derivation when the inputs reproduce it; else it's an inference.
            return c.hasReproducibleDerivation ? .assertAsDerivation : .presentAsInference
        case .inferred:
            return .presentAsInference          // defensive (handled at rule 4)
        case .unknownLegacy:
            // Unknown basis, no human action (handled at rule 6): attribute conservatively.
            return .assertWithAttribution
        }
    }
}
