//
//  FactMemoComposer.swift
//  Kalsmritikosh
//
//  PA-CUT-MEMO — the registry composer for the `.factMemo` template, replacing its legacy
//  whole-archive route. Pure, synchronous, deterministic, LLM-free and repository-free: it
//  renders ONLY the already-selected, review-resolved, workspace-scoped `context.selectedClaims`
//  (plus the upstream-scoped conflicts/gaps) through the canonical ResolvedClaimRenderer and the
//  SHARED bucketing/disclosure helpers — never a parallel trust decision, never a global read.
//
//  A fact memo answers ONE question (the workspace/subject label) strictly from the evidence:
//  supported facts, qualified (inference) observations, disputed points (both sides preserved),
//  and the proof that is missing. The short answer is a deterministic COUNT summary only — it
//  reaches no uncited conclusion of its own.
//

import Foundation

public struct FactMemoComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("fact-memo.core") }
    public var sectionKind: BlueprintSection.Kind { .summary }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        // Same bucketing rule the sourced summary uses: render each surfaceable claim once and
        // split by how it is grounded (assertive → supported, inference → qualified, conflict →
        // claim-level dispute). Stable input order preserved within each bucket.
        let bucketed = WorkProductClaimBucketing.bucket(context.selectedClaims)

        // Disputed = claim-level conflicts + the workspace-scoped SelectedConflicts (both sides
        // preserved, never chosen or averaged); Missing proof = the workspace-scoped gaps.
        let disputed = bucketed.claimLevelConflicts
            + WorkProductDisclosureRendering.conflictClaims(context.selectedConflicts)
        let missing = WorkProductDisclosureRendering.gapClaims(context.selectedGaps)

        let question = WorkProductSection(title: "Question presented", preamble: [
            "Question: \(context.subjectLabel)",
            "This memo answers the question strictly from the sources in scope; it reaches no conclusion beyond them."])

        // Deterministic count summary ONLY — no uncited conclusion is asserted here.
        let shortAnswer = WorkProductSection(title: "Short answer", preamble: [
            "\(bucketed.supported.count) supported fact(s), \(bucketed.qualified.count) qualified observation(s), \(disputed.count) disputed point(s) and \(missing.count) missing-proof gap(s) in scope. See the sections below for each, with citations."])

        return [
            question,
            shortAnswer,
            section("Supported facts", bucketed.supported,
                    nonEmpty: "supported fact(s), each labelled by how it is grounded and citing a reopenable source.",
                    empty: "No supported facts in scope."),
            section("Qualified observations", bucketed.qualified,
                    nonEmpty: "observation(s) offered as inference — not asserted as fact.",
                    empty: "No qualified observations in scope."),
            section("Disputed facts", disputed,
                    nonEmpty: "disputed point(s) — both accounts remain; neither is chosen or averaged.",
                    empty: "No disputed facts in scope."),
            section("Missing proof", missing,
                    nonEmpty: "missing-evidence gap(s) — the expected material may exist outside the indexed archive; absence is not proof.",
                    empty: "No missing-proof gaps in scope."),
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
