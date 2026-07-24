//
//  GapsAndConflictsComposer.swift
//  Kalsmritikosh
//
//  PA-WP (disclosure composer). Renders the workspace-scoped CONFLICTS and GAPS that were
//  prepared UPSTREAM (DisclosureSelectionService) into two disclosure sections. The composer
//  is pure, synchronous, deterministic, LLM-free and touches NO repositories — it must never
//  call ContradictionsRepository.all() / GapNodeRepository.all() (that is the whole-archive
//  leakage the scoped pipeline removed). Everything it renders is a DISCLOSURE (`.inference`
//  framing): a conflict shows both sides without choosing or averaging; a gap states that
//  absence is not proof. Disclosures never count as material assertions, so they cannot
//  satisfy a material-evidence minimum and never trip the fail-closed export gate.
//
//  The output model has no sub-section concept, so this returns two WorkProductSections in a
//  stable order: conflicts first, gaps second.
//

import Foundation

public struct GapsAndConflictsComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("evidence.gaps-conflicts") }
    public var sectionKind: BlueprintSection.Kind { .gapsAndConflicts }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        [conflictsSection(context.selectedConflicts), gapsSection(context.selectedGaps)]
    }

    // MARK: - Conflicts

    private func conflictsSection(_ conflicts: [SelectedConflict]) -> WorkProductSection {
        // Shared disclosure rendering (same rule the fact memo's Disputed-facts section uses):
        // both sides preserved, two separate citation lists, never merged or scored.
        let claims = WorkProductDisclosureRendering.conflictClaims(conflicts)
        let preamble = claims.isEmpty
            ? ["No conflicting accounts found in scope."]
            : ["Conflicting accounts are shown with both sides preserved; neither side is chosen or averaged."]
        return WorkProductSection(title: "Conflicts", preamble: preamble, claims: claims)
    }

    // MARK: - Gaps

    private func gapsSection(_ gaps: [SelectedGap]) -> WorkProductSection {
        // Shared disclosure rendering (same rule the fact memo's Missing-proof section uses):
        // inference-framed, citation-free — absence is explicitly not proof.
        let claims = WorkProductDisclosureRendering.gapClaims(gaps)
        let preamble = claims.isEmpty
            ? ["No missing-evidence gaps found in scope."]
            : ["Each gap is a reasoned observation of ABSENCE — the expected material may exist outside the indexed archive; absence is not proof."]
        return WorkProductSection(title: "Gaps", preamble: preamble, claims: claims)
    }
}
