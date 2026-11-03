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

        let findings = Self.distinctFindings(Self.hygienic(rendered))

        // Materials-reviewed counts — SELECTED CONTEXT ONLY (no global event/contradiction/gap reads).
        var objects = Set<KnowledgeObject.ID>()
        var versions = Set<UUID>()
        for pair in rendered {
            for ev in pair.selected.resolved.claim.evidence {
                objects.insert(ev.objectID)
                if let v = ev.sourceVersionID { versions.insert(v) }
            }
        }
        // Counted over the rows shown (an "Undated…" phrase marks an undated row).
        let undated = findings.filter { $0.text.hasPrefix("Undated") }.count
        let dated = findings.count - undated

        let mandate = WorkProductSection(title: "Mandate / scope", preamble: [
            "This report concerns the \"\(context.subjectLabel)\" workspace. It presents only findings supported by the sources added to that workspace, and reaches no conclusion beyond them."])

        let materials = WorkProductSection(title: "Materials reviewed", preamble: [
            "\(findings.count) surfaceable finding(s) drawn from \(objects.count) source document(s) across \(versions.count) source version(s).",
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

    /// Findings rows: each prefixed with its precision-honest date (undated / conflicting are
    /// stated explicitly), preserving status / decision / review / sourceClaimID / citations.
    ///
    /// Case bench 2026-10-20: one fact reaches the ledger through several producers (the incident
    /// event, the labeled "Event date" field, the story spine), so the report listed "On
    /// 2017-01-11 — Event: Employee crushes hand in press track" three times. A row that reads
    /// exactly like an earlier one is the same finding: it is shown once, carrying every
    /// citation that supports it (none is dropped).
    static func distinctFindings(_ rendered: [(selected: SelectedClaim, claim: WorkProductClaim)]) -> [WorkProductClaim] {
        var out: [WorkProductClaim] = []
        var index: [String: Int] = [:]
        for pair in rendered {
            var c = pair.claim
            c.text = "\(SelectedClaimDatePhrase.phrase(for: pair.selected)) — \(c.text)"
            let key = c.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = index[key] {
                for citation in c.supporting where !out[i].supporting.contains(citation) {
                    out[i].supporting.append(citation)
                }
                for citation in c.contradicting where !out[i].contradicting.contains(citation) {
                    out[i].contradicting.append(citation)
                }
            } else {
                index[key] = out.count
                out.append(c)
            }
        }
        return out
    }

    /// The number of distinct findings the report shows — what the executive summary counts.
    static func distinctFindingCount(_ context: WorkProductContext) -> Int {
        distinctFindings(hygienic(context.selectedClaims.compactMap { sel in
            ResolvedClaimRenderer.render(sel).map { (sel, $0.workProductClaim) }
        })).count
    }

    // MARK: - P4 findings hygiene (real-case evaluation 2026-11-03, D5)

    /// The rows a report may carry: no "field: value" row whose field is a person's surname or whose
    /// value is a list item or a defence-counsel line ("gillar: Thomas Ashley Esq., Newark",
    /// "hutchins: • Rapids Theatre Niagara Falls, USA, Inc."), and one row per person and step — two
    /// documents dating one plea a few weeks apart are one step with a date discrepancy, shown as
    /// such, never two pleas.
    static func hygienic(_ rendered: [(selected: SelectedClaim, claim: WorkProductClaim)]) -> [(selected: SelectedClaim, claim: WorkProductClaim)] {
        // The people the case's claims are about (participant subjects of event claims).
        var surnames = Set<String>()
        for pair in rendered where pair.selected.resolved.claim.derivedFrom.contains(where: { $0.kind == .event }) && pair.selected.resolved.claim.subjectID != nil {
            let words = pair.selected.resolved.claim.subjectLabel.lowercased()
                .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted).filter { $0.count >= 2 }
            if words.count >= 2, let last = words.last { surnames.insert(last) }
        }
        let kept = rendered.filter { pair in
            guard pair.selected.resolved.claim.derivedFrom.contains(where: { $0.kind == .genericFact }),
                  let colon = pair.claim.text.range(of: ": ") else { return true }
            let field = pair.claim.text[..<colon.lowerBound].lowercased().trimmingCharacters(in: .whitespaces)
            let value = pair.claim.text[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            if surnames.contains(field) { return false }
            if let head = value.first, "•·▪◦‣●".contains(head) { return false }
            if value.range(of: #"(?i)\besq\b"#, options: .regularExpression) != nil { return false }
            return true
        }
        return collapsingStepDiscrepancies(kept)
    }

    /// "Guy R. Miller sentenced" from two documents, dated May 28 and May 29: one row, at the earlier
    /// day, carrying both documents' citations and the discrepancy.
    static func collapsingStepDiscrepancies(_ rendered: [(selected: SelectedClaim, claim: WorkProductClaim)]) -> [(selected: SelectedClaim, claim: WorkProductClaim)] {
        let stepSuffix = #"\s(?:charged|arrested|arraigned|pleaded guilty|convicted|acquitted|sentenced|pardoned|released)\.?$"#
        var out: [(selected: SelectedClaim, claim: WorkProductClaim)] = []
        var groups: [String: [Int]] = [:]
        var extraDays: [Int: [String]] = [:]
        for pair in rendered {
            let c = pair.selected.resolved.claim
            guard let anchor = pair.selected.temporalAnchor, let subject = c.subjectID,
                  c.derivedFrom.contains(where: { $0.kind == .event }),
                  c.statement.range(of: stepSuffix, options: .regularExpression) != nil else { out.append(pair); continue }
            let key = subject.uuidString + "|" + c.statement.lowercased()
            if let i = groups[key, default: []].first(where: { i in
                guard let a = out[i].selected.temporalAnchor else { return false }
                return abs(a.start.timeIntervalSince(anchor.start)) <= 60 * 86_400
            }) {
                let day = SelectedClaimDatePhrase.phrase(for: pair.selected).replacingOccurrences(of: "On ", with: "")
                let first = SelectedClaimDatePhrase.phrase(for: out[i].selected).replacingOccurrences(of: "On ", with: "")
                if day != first, !(extraDays[i] ?? []).contains(day) { extraDays[i, default: []].append(day) }
                for citation in pair.claim.supporting where !out[i].claim.supporting.contains(citation) { out[i].claim.supporting.append(citation) }
                for citation in pair.claim.contradicting where !out[i].claim.contradicting.contains(citation) { out[i].claim.contradicting.append(citation) }
                continue
            }
            groups[key, default: []].append(out.count)
            out.append(pair)
        }
        for (i, days) in extraDays {
            let first = SelectedClaimDatePhrase.phrase(for: out[i].selected).replacingOccurrences(of: "On ", with: "")
            out[i].claim.text += " (the sources give different dates: " + ([first] + days).joined(separator: ", ") + " — one step, a date discrepancy)"
        }
        return out
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
        let findings = InvestigationFindingsComposer.distinctFindingCount(context)
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
