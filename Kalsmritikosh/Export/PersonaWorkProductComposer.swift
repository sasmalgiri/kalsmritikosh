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
                claims = facts.filter(\.isMaterialAndSupported).map { f in
                    ComposedClaim(text: "\(f.field): \(f.value)", sourceBlockIDs: f.sourceBlockIDs, status: f.status)
                }
            case .relationships, .exhibitList:
                claims = facts.filter(\.isMaterialAndSupported).prefix(20).map { f in
                    ComposedClaim(text: "\(f.subjectLabel) — \(f.field)", sourceBlockIDs: f.sourceBlockIDs, status: f.status)
                }
            case .gapsAndConflicts:
                claims = []   // non-claim section; validator does not require evidence here
            }
            for c in claims { manifest.formUnion(c.sourceBlockIDs) }
            sections.append(ComposedSection(blueprint: bp, claims: claims))
        }

        return ComposedWorkProduct(blueprint: blueprint, sections: sections, manifestSourceIDs: manifest)
    }
}
