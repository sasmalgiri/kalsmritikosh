//
//  ClaimMatrixComposer.swift
//  Kalsmritikosh
//
//  PA-WP (second section composer). A claim/evidence MATRIX: one row per selected claim,
//  each carrying its EXACT canonical presentation category (Observed fact / Source-reported /
//  Independently corroborated / Deterministically derived / User-confirmed / Inference /
//  Conflicting accounts) — distinctions the coarser EpistemicStatus collapses. Shared by the
//  journalism "Claims & Sources" and research "Findings Matrix" blueprints (both `.matrix`).
//
//  Pure, synchronous, deterministic, LLM-free. Renders ONLY WorkProductContext.selectedClaims;
//  no repository access, no independent selection. Trust comes from AssertabilityPolicy on the
//  effective assessment (via ResolvedClaimRenderer) — never a parallel rule. Unlike the
//  chronology composer, the matrix does not depend on temporal anchors: dated and undated
//  claims are equally valid rows.
//

import Foundation

public struct ClaimMatrixComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("claims.matrix") }
    public var sectionKind: BlueprintSection.Kind { .matrix }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        // Deterministic context order preserved; refused claims dropped by the renderer.
        let claims: [WorkProductClaim] = context.selectedClaims.compactMap { selected in
            guard let rendered = ResolvedClaimRenderer.render(selected) else { return nil }
            var wp = rendered.workProductClaim
            // Prefix the EXACT presentation category (the matrix's classification column),
            // preserving the claim text, citations, review, confidence and identity.
            wp.text = "\(Self.categoryLabel(rendered.presentation)): \(wp.text)"
            return wp
        }
        return [WorkProductSection(
            title: "Claim Matrix",
            preamble: ["Each row is classified by how it is grounded; corroboration requires independent sources. Supporting and contradicting sources are listed separately."],
            claims: claims)]
    }

    /// The exact, human-facing label for each canonical presentation category — the one shared
    /// mapping (`ClaimPresentation.displayLabel`). Complete over all seven surfaced
    /// presentations (refuse is excluded before this point).
    nonisolated static func categoryLabel(_ p: ClaimPresentation) -> String { p.displayLabel }
}
