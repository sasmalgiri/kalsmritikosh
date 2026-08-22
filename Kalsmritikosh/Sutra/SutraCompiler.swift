//
//  SutraCompiler.swift
//  Kalsmritikosh
//
//  Folds the machine-readable sources — JobToolingCatalog (tier / method /
//  surface) + SutraDoctrine (obligations / human decisions / prohibited) — into a
//  single Sutra. Personas are lenses over this one shared doctrine, so the
//  compiled Sutra is the same constitution every profession runs on; a persona
//  only relabels it.
//

import Foundation

public nonisolated enum SutraCompiler {

    /// The shared investigation doctrine — 16 phases in catalog order.
    public static func shared() -> Sutra {
        let phases: [SutraPhase] = JobToolingCatalog.profiles.compactMap { profile in
            let d = SutraDoctrine.doctrine(for: profile.kind)
            return SutraPhase(
                kind: profile.kind,
                title: SutraDoctrine.title(profile.kind),
                tier: profile.tier,
                method: profile.method,
                surface: profile.surface,
                obligations: d.obligations,
                humanDecisions: d.humanDecisions,
                prohibitedConclusions: d.prohibited)
        }
        return Sutra(
            id: "sutra.investigation",
            version: 1,
            title: "Investigation doctrine",
            provenance: "Derived from the SOP-grounded job-depth map and recognized standards — Admiralty/NATO source rating, Analysis of Competing Hypotheses (Heuer), SWGDE/NIST chain of custody, NAIC/NICB SIU, GPS, PRISMA/GRADE, FRCP privilege.",
            reliabilityScale: "Admiralty — source reliability A–F × information credibility 1–6",
            phases: phases,
            standardsOfProof: EvidentiaryStandard.allCases,
            reportSections: ["Problem / mandate", "Evidence & custody", "Analysis",
                             "Findings (with standard of proof)", "Open items", "Sign-off & seal"])
    }

    /// A persona's constitution. Personas are lenses over the shared doctrine, so
    /// this is the shared Sutra with the persona's title applied. (Vocabulary
    /// overrides and persona-specific prohibited conclusions can be layered here.)
    public static func sutra(forPersonaLabel label: String) -> Sutra {
        let base = shared()
        return Sutra(id: base.id + "." + label.lowercased().replacingOccurrences(of: " ", with: "-"),
                     version: base.version,
                     title: "\(label) — \(base.title)",
                     provenance: base.provenance,
                     reliabilityScale: base.reliabilityScale,
                     phases: base.phases,
                     standardsOfProof: base.standardsOfProof,
                     reportSections: base.reportSections)
    }
}
