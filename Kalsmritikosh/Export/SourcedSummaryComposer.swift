//
//  SourcedSummaryComposer.swift
//  Kalsmritikosh
//
//  PA-WP (fourth section composer). A sourced summary of the workspace's claims, split by how
//  each is grounded. Pure, synchronous, deterministic, LLM-free; limited to
//  WorkProductContext.selectedClaims; repository-free; trust comes only from
//  ResolvedClaimRenderer.render (AssertabilityPolicy on the effective assessment). Complete
//  over all surfaceable claims — no "top N" truncation. Refused claims are excluded; a
//  disclosure (inference / conflict) is NEVER placed in the sourced-fact section.
//

import Foundation

public struct SourcedSummaryComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("claims.sourced-summary") }
    public var sectionKind: BlueprintSection.Kind { .summary }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        // Shared bucketing rule (same one the fact memo uses): render each surfaceable claim once
        // and split by how it is grounded. Stable input order is preserved within each bucket.
        let bucketed = WorkProductClaimBucketing.bucket(context.selectedClaims)
        return [
            section("Sourced summary", bucketed.supported,
                    nonEmpty: "sourced fact(s), each labelled by how it is grounded and citing a reopenable source.",
                    empty: "No sourced facts in scope."),
            section("Qualified observations", bucketed.qualified,
                    nonEmpty: "observation(s) offered as inference — not asserted as fact.",
                    empty: "No qualified observations in scope."),
            section("Claim-level conflicts", bucketed.claimLevelConflicts,
                    nonEmpty: "conflicting claim(s) — both accounts remain; neither is chosen or averaged.",
                    empty: "No claim-level conflicts in scope."),
        ]
    }

    /// Preamble is deterministic prose (a count + description) — never an evidence-required
    /// material claim.
    private func section(_ title: String, _ claims: [WorkProductClaim],
                         nonEmpty: String, empty: String) -> WorkProductSection {
        let preamble = claims.isEmpty ? empty : "\(claims.count) \(nonEmpty)"
        return WorkProductSection(title: title, preamble: [preamble], claims: claims)
    }
}
