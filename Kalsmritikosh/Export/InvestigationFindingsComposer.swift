//
//  InvestigationFindingsComposer.swift
//  Kalsmritikosh
//
//  PA-CUT-INV — the registry composers for the `.investigationFindings` template, replacing its
//  legacy whole-archive route. Both are pure, synchronous, deterministic, LLM-free and
//  repository-free: they render ONLY the already-selected, review-resolved, workspace-scoped
//  `context.selectedClaims` (and the upstream-scoped conflicts/gaps) through the canonical
//  ResolvedClaimRenderer — never a parallel trust decision, never a global repository read.
//

import Foundation

/// Findings composer → four sections in order: Mandate / scope, Materials reviewed, Methods,
/// Findings. The Findings rows are the surfaceable Claims (refused dropped), each date-phrased by
/// the shared precision-honest helper and carrying its exact decision + citations. Counts are
/// derived ONLY from the selected context.
public struct InvestigationFindingsComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("investigation.findings") }
    public var sectionKind: BlueprintSection.Kind { .narrative }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        // Render every surfaceable claim ONCE (refused → dropped). No top-N truncation.
        let rendered: [(selected: SelectedClaim, claim: WorkProductClaim)] = context.selectedClaims.compactMap { sel in
            guard let r = ResolvedClaimRenderer.render(sel) else { return nil }
            return (sel, r.workProductClaim)
        }

        // Findings rows: prefix each with its precision-honest date (undated / conflicting are
        // stated explicitly), preserving status / decision / review / sourceClaimID / citations.
        let findings = rendered.map { pair -> WorkProductClaim in
            var c = pair.claim
            c.text = "\(SelectedClaimDatePhrase.phrase(for: pair.selected)) — \(c.text)"
            return c
        }

        // Materials-reviewed counts — SELECTED CONTEXT ONLY (no global event/contradiction/gap reads).
        var objects = Set<KnowledgeObject.ID>()
        var versions = Set<UUID>()
        var dated = 0, undated = 0
        for pair in rendered {
            for ev in pair.selected.resolved.claim.evidence {
                objects.insert(ev.objectID)
                if let v = ev.sourceVersionID { versions.insert(v) }
            }
            if pair.selected.temporalAnchor != nil { dated += 1 } else { undated += 1 }
        }

        let mandate = WorkProductSection(title: "Mandate / scope", preamble: [
            "This report concerns the \"\(context.subjectLabel)\" workspace. It presents only findings supported by the sources added to that workspace, and reaches no conclusion beyond them."])

        let materials = WorkProductSection(title: "Materials reviewed", preamble: [
            "\(rendered.count) surfaceable finding(s) drawn from \(objects.count) source document(s) across \(versions.count) source version(s).",
            "\(dated) dated and \(undated) undated finding(s); \(context.selectedConflicts.count) conflict(s) and \(context.selectedGaps.count) evidence gap(s) in scope."])

        let methods = WorkProductSection(title: "Methods", preamble: [
            "Findings were assembled deterministically from workspace-scoped, review-resolved Claims using fixed rules. No generative model and no external data were used; every material finding cites a reopenable source and is labelled by how it is grounded."])

        let findingsSection = WorkProductSection(
            title: "Findings",
            preamble: [findings.isEmpty
                ? "No findings in scope for this workspace's sources."
                : "\(findings.count) finding(s), each labelled by how it is grounded and dated by its evidence."],
            claims: findings)

        return [mandate, materials, methods, findingsSection]
    }
}

/// Executive-summary composer → one prose section placed FIRST, so a non-technical reader
/// (counsel, a manager) grasps the whole report in under a minute. Pure prose (no material
/// claims) → never trips the evidence gate; counts come ONLY from the selected context, and it
/// reaches no conclusion beyond the evidence.
public struct InvestigationExecutiveSummaryComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("investigation.execsummary") }
    public var sectionKind: BlueprintSection.Kind { .narrative }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        let findings = context.selectedClaims.count
        let conflicts = context.selectedConflicts.count
        let gaps = context.selectedGaps.count
        let line1 = findings == 0
            ? "No findings are supported by the sources in the \"\(context.subjectLabel)\" workspace."
            : "\(findings) finding(s) are supported by the sources in the \"\(context.subjectLabel)\" workspace."
        let line2 = "\(conflicts) unresolved conflict(s) and \(gaps) evidence gap(s) remain to be weighed before relying on these findings."
        let line3 = "Read the full report below; every finding cites a reopenable source and is labelled by how it is grounded. This summary reaches no conclusion beyond the evidence."
        return [WorkProductSection(title: "Executive summary", preamble: [line1, line2, line3])]
    }
}

/// Limitations composer → one disclosure section. Pure prose (no material claims), so it never
/// trips the fail-closed evidence gate. States the honest bounds of the report.
public struct InvestigationLimitationsComposer: WorkProductSectionComposer {
    public nonisolated init() {}

    public var id: WorkProductComposerID { WorkProductComposerID("investigation.limitations") }
    public var sectionKind: BlueprintSection.Kind { .narrative }

    public func compose(_ context: WorkProductContext) -> [WorkProductSection] {
        [WorkProductSection(title: "Limitations", preamble: [
            "These findings reflect ONLY the sources added to this workspace; material outside it was not considered.",
            "Absence of a finding is not proof that something did not happen — expected material may exist outside the indexed sources.",
            "This report does not determine admissibility, liability, or any professional (legal, medical, financial) conclusion.",
            "Inferred and conflicting material is shown and labelled as such; it is never presented as established fact."])]
    }
}
