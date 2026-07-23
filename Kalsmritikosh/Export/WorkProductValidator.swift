//
//  WorkProductValidator.swift
//  Kalsmritikosh
//
//  EXP-002 — validate a composed work product against its blueprint (PER-002) and the
//  claim–evidence contract before it can be exported. Every claim-bearing section must have
//  claims; every material claim must carry at least the blueprint's required evidence; and
//  the export manifest must list every source a claim cites (nothing cited-but-unlisted).
//
//  Pure, deterministic. Round-trip safe: validation depends only on the composed structure,
//  so re-validating an exported package reproduces the same verdict.
//

import Foundation

public struct ComposedClaim: Sendable, Hashable {
    public let text: String
    public let sourceBlockIDs: [UUID]
    public let status: EvidenceStatus
    /// S0.5 item 2 C2 — the canonical assertability evaluation for a production claim
    /// derived from the answer path. When present the validator VERIFIES it (anti-tamper);
    /// when absent (fact-composed export) the validator gates via the policy from the
    /// claim's blocks — never via the deprecated `status.isAssertable`.
    public let evaluation: ClaimEvaluation?

    public nonisolated init(text: String, sourceBlockIDs: [UUID], status: EvidenceStatus,
                            evaluation: ClaimEvaluation? = nil) {
        self.text = text; self.sourceBlockIDs = sourceBlockIDs; self.status = status
        self.evaluation = evaluation
    }
}

public struct ComposedSection: Sendable, Hashable {
    public let blueprint: BlueprintSection
    public let claims: [ComposedClaim]
    public nonisolated init(blueprint: BlueprintSection, claims: [ComposedClaim]) {
        self.blueprint = blueprint; self.claims = claims
    }
}

public struct ComposedWorkProduct: Sendable, Hashable {
    public let blueprint: WorkProductBlueprint
    public let sections: [ComposedSection]
    /// Source blocks listed in the export manifest.
    public let manifestSourceIDs: Set<UUID>
    public nonisolated init(blueprint: WorkProductBlueprint, sections: [ComposedSection], manifestSourceIDs: Set<UUID>) {
        self.blueprint = blueprint; self.sections = sections; self.manifestSourceIDs = manifestSourceIDs
    }
}

public struct WorkProductValidator: Sendable {
    public nonisolated init() {}

    /// C2.1 Part 3B — adapt the PRODUCTION `WorkProduct` (what WorkspacesView actually
    /// exports) into the validated `ComposedWorkProduct`, gating ONLY material claims. A
    /// material claim (direct evidence / source assertion / deterministic derivation) must
    /// carry a RESOLVED, block-backed citation; inference and human-note claims are
    /// disclosures and are not required to carry evidence, so they're excluded from the
    /// evidence-required set (never fabricated, never blocked). This lets the export fail
    /// CLOSED on an unsupported material claim without rejecting legitimate labelled
    /// disclosures.
    public nonisolated static func materialComposition(from wp: WorkProduct) -> ComposedWorkProduct {
        func isMaterial(_ s: EpistemicStatus) -> Bool {
            switch s {
            case .directEvidence, .sourceAssertion, .deterministicDerivation: return true
            case .inference, .humanNote: return false
            }
        }
        func mapStatus(_ s: EpistemicStatus) -> EvidenceStatus {
            switch s {
            case .directEvidence:          return .directlyObserved
            case .sourceAssertion:         return .sourceAsserted
            case .deterministicDerivation: return .deterministicallyDerived
            case .inference:               return .inferred
            case .humanNote:               return .unsupported
            }
        }
        var manifest = Set<UUID>()
        var sections: [ComposedSection] = []
        for sec in wp.sections {
            let material = sec.claims.filter { isMaterial($0.status) }
            let composed = material.map { c -> ComposedClaim in
                // Only RESOLVED citations contribute blocks → a material claim backed only by
                // unresolved citations has zero exact evidence and will be blocked.
                let blocks = c.supporting.filter(\.isResolved).flatMap(\.evidenceBlockIDs)
                manifest.formUnion(blocks)
                return ComposedClaim(text: c.text, sourceBlockIDs: blocks, status: mapStatus(c.status))
            }
            let bp = BlueprintSection(title: sec.title, kind: .matrix,
                                      requiresEvidence: !material.isEmpty, minEvidencePerClaim: 1)
            sections.append(ComposedSection(blueprint: bp, claims: composed))
        }
        let blueprint = WorkProductBlueprint(name: wp.title, persona: .general, sections: sections.map(\.blueprint))
        return ComposedWorkProduct(blueprint: blueprint, sections: sections, manifestSourceIDs: manifest)
    }

    public enum Violation: Sendable, Hashable {
        case sectionMissingClaims(section: String)
        case claimUnderEvidenced(section: String, claim: String, has: Int, needs: Int)
        /// The claim's policy decision is not a material assertion (inference / conflict /
        /// refuse) — it may not stand as an evidence-required export claim.
        case claimUnsupportedStatus(section: String, claim: String, status: String)
        case citedSourceNotInManifest(section: String, claim: String, sourceID: UUID)
        /// A carried evaluation's decision does not match its own recorded context — tampering.
        case claimDecisionMismatch(section: String, claim: String)
        /// A carried evaluation's presentation is not the required mapping for its decision.
        case claimPresentationMismatch(section: String, claim: String)
    }

    public struct Report: Sendable {
        public let violations: [Violation]
        public var isValid: Bool { violations.isEmpty }
    }

    /// The policy decision for a composed claim: from its carried evaluation when present,
    /// else re-derived from the claim's blocks (exact citations, no independence → no
    /// corroboration). NEVER via the deprecated `status.isAssertable`.
    private nonisolated func decision(for claim: ComposedClaim) -> AssertabilityDecision {
        if let eval = claim.evaluation { return eval.decision }
        let blocks = Set(claim.sourceBlockIDs)
        let ctx = AssertabilityContext(
            assessment: LegacyEvidenceStatusAdapter.decode(claim.status),
            exactEvidenceCount: blocks.count, independentEvidenceGroupCount: 0,
            hasExactLocator: !blocks.isEmpty, hasReproducibleDerivation: false)
        return AssertabilityPolicy.evaluate(ctx)
    }

    public nonisolated func validate(_ wp: ComposedWorkProduct) -> Report {
        var v: [Violation] = []
        for section in wp.sections {
            let bp = section.blueprint
            if bp.requiresEvidence && section.claims.isEmpty {
                v.append(.sectionMissingClaims(section: bp.title))
            }
            for claim in section.claims {
                if bp.requiresEvidence {
                    let d = decision(for: claim)
                    // Anti-tamper: a carried evaluation must be internally consistent — its
                    // decision must match its recorded context, and its presentation must be
                    // exactly the mapping for that decision (no strengthening/mislabelling).
                    if let eval = claim.evaluation {
                        if AssertabilityPolicy.evaluate(eval.context) != eval.decision {
                            v.append(.claimDecisionMismatch(section: bp.title, claim: claim.text))
                        }
                        if eval.presentation != ClaimPresentation(decision: eval.decision) {
                            v.append(.claimPresentationMismatch(section: bp.title, claim: claim.text))
                        }
                    }
                    // A material export claim must be a genuine assertion (not inference /
                    // conflict / refuse) — decided by the policy, never by isAssertable.
                    if !d.isAssertiveDecision {
                        v.append(.claimUnsupportedStatus(section: bp.title, claim: claim.text, status: d.rawValue))
                    }
                    // … at least the blueprint's required evidence count …
                    if claim.sourceBlockIDs.count < bp.minEvidencePerClaim {
                        v.append(.claimUnderEvidenced(section: bp.title, claim: claim.text,
                                                      has: claim.sourceBlockIDs.count, needs: bp.minEvidencePerClaim))
                    }
                    // … and every cited source must be in the manifest.
                    for sid in claim.sourceBlockIDs where !wp.manifestSourceIDs.contains(sid) {
                        v.append(.citedSourceNotInManifest(section: bp.title, claim: claim.text, sourceID: sid))
                    }
                }
            }
        }
        return Report(violations: v)
    }
}
