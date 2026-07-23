//
//  PersonaWorkProductComposer.swift
//  Kalsmritikosh
//
//  PER-003…007 — ONE deterministic composer that builds a persona's work product from its
//  blueprint (PER-002). Because each persona's sections are declared as data, a single
//  composer serves all five (lawyer/investigator/journalist/researcher/individual) — no
//  per-persona code branch. It wires the building blocks together:
//    • chronology/deadlines sections ← DeterministicReconstruction (REC-003), cited
//    • narrative/summary/matrix/… sections ← evidence-linked GenericFacts (SEM)
//    • gaps/conflicts sections ← non-claim (no evidence required)
//  The output is a ComposedWorkProduct that EXP-002's validator can gate before export.
//
//  Deterministic, offline. Every claim carries its source; a section with no backing facts
//  is left empty (and will be flagged by the validator rather than filled with fabrication).
//

import Foundation

public struct PersonaWorkProductComposer: Sendable {
    public nonisolated init() {}

    private let recon = DeterministicReconstruction()

    /// Compose a work product for `blueprint` from the given evidence.
    /// - facts: evidence-linked GenericFacts (subject/field/value).
    /// - events: dated events (for chronology/deadlines/reconstruction sections).
    public nonisolated func compose(
        blueprint: WorkProductBlueprint,
        facts: [GenericFact],
        events: [Event]
    ) -> ComposedWorkProduct {
        var sections: [ComposedSection] = []
        var manifest = Set<UUID>()

        for bp in blueprint.sections {
            let claims: [ComposedClaim]
            switch bp.kind {
            case .chronology, .deadlines:
                claims = recon.outline(from: events).dated.map { entry in
                    ComposedClaim(text: "\(entry.dateLabel) — \(entry.title)",
                                  sourceBlockIDs: [entry.sourceObjectID], status: .sourceAsserted)
                }
            case .narrative, .summary, .matrix, .transactions, .bibliography:
                claims = facts.filter { Self.isAssertive($0) }.map { f in
                    ComposedClaim(text: "\(f.field): \(f.value)", sourceBlockIDs: f.sourceBlockIDs,
                                  status: LegacyEvidenceStatusAdapter.encode(f.assessment))
                }
            case .relationships, .exhibitList:
                claims = facts.filter { Self.isAssertive($0) }.prefix(20).map { f in
                    ComposedClaim(text: "\(f.subjectLabel) — \(f.field)", sourceBlockIDs: f.sourceBlockIDs,
                                  status: LegacyEvidenceStatusAdapter.encode(f.assessment))
                }
            case .gapsAndConflicts:
                claims = []   // non-claim section; validator does not require evidence here
            }
            for c in claims { manifest.formUnion(c.sourceBlockIDs) }
            sections.append(ComposedSection(blueprint: bp, claims: claims))
        }

        return ComposedWorkProduct(blueprint: blueprint, sections: sections, manifestSourceIDs: manifest)
    }

    /// Whether a fact may stand as a material export claim — decided by AssertabilityPolicy
    /// (S0.5 item 2 C2), NOT by the deprecated `isMaterialAndSupported`. Evidence is the
    /// fact's exact blocks; independence is unknown here (no corroboration); blocks are exact
    /// locators. A fact with no blocks has no exact citation → refused.
    nonisolated static func isAssertive(_ f: GenericFact) -> Bool {
        let blocks = Set(f.sourceBlockIDs)
        let ctx = AssertabilityContext(
            assessment: f.assessment, exactEvidenceCount: blocks.count,
            independentEvidenceGroupCount: 0, hasExactLocator: !blocks.isEmpty,
            hasReproducibleDerivation: false)
        return AssertabilityPolicy.evaluate(ctx).isAssertiveDecision
    }
}
