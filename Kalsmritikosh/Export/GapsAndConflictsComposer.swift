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
        let ordered = conflicts.sorted { a, b in
            Self.severityRank(a.severity) != Self.severityRank(b.severity)
                ? Self.severityRank(a.severity) < Self.severityRank(b.severity)   // high first
                : a.id.uuidString < b.id.uuidString
        }
        let claims = ordered.map { c -> WorkProductClaim in
            // Two opposing sides → two SEPARATE citation lists (side A supporting, side B
            // contradicting). Never merged, never scored.
            let cites = c.evidence.enumerated().map { (i, ev) in
                CitationRecord(sourceVersionID: ev.sourceVersionID,
                               evidenceBlockIDs: ev.blockID.map { [$0] } ?? [],
                               displayLabel: "[\(i + 1)]", sourceTitle: c.description)
            }
            let supporting = zip(cites, c.evidence).filter { $0.1.role != .contradicts }.map(\.0)
            let contradicting = zip(cites, c.evidence).filter { $0.1.role == .contradicts }.map(\.0)
            return WorkProductClaim(
                text: "Conflicting accounts:\nA: \(c.sideA)\nB: \(c.sideB)",
                status: .inference,                          // a disclosure, not a source assertion
                supporting: supporting, contradicting: contradicting)
        }
        let preamble = claims.isEmpty
            ? ["No conflicting accounts found in scope."]
            : ["Conflicting accounts are shown with both sides preserved; neither side is chosen or averaged."]
        return WorkProductSection(title: "Conflicts", preamble: preamble, claims: claims)
    }

    private static func severityRank(_ s: Contradiction.Severity) -> Int {
        switch s { case .high: return 0; case .medium: return 1; case .low: return 2 }
    }

    // MARK: - Gaps

    private func gapsSection(_ gaps: [SelectedGap]) -> WorkProductSection {
        let ordered = gaps.sorted { a, b in
            if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
            if a.confidence != b.confidence { return a.confidence > b.confidence }   // higher confidence first
            return a.id.uuidString < b.id.uuidString
        }
        let claims = ordered.map { g -> WorkProductClaim in
            // A gap is inference-framed and CITATION-FREE — no fabricated citation to make the
            // row look supported. Absence is explicitly not proof.
            WorkProductClaim(
                text: "Missing evidence: \(g.description)\nReason: \(g.reason)\nThe expected material may exist outside the indexed archive.",
                status: .inference, supporting: [], contradicting: [])
        }
        let preamble = claims.isEmpty
            ? ["No missing-evidence gaps found in scope."]
            : ["Each gap is a reasoned observation of ABSENCE — the expected material may exist outside the indexed archive; absence is not proof."]
        return WorkProductSection(title: "Gaps", preamble: preamble, claims: claims)
    }
}
