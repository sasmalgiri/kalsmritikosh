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

    /// STEP 5 — a SECOND discipline, authored as a Sūtra alone (no new UI, no new
    /// engine). Clinical differential diagnosis IS an Analysis of Competing
    /// Hypotheses: diagnoses are the hypotheses, findings are the evidence, and
    /// you rule out by disconfirming — so the differential phase reuses the exact
    /// same ACH matrix ("hypotheses" surface) and the same conformance gates.
    /// Illustrative only — not medical advice.
    public static func clinicalDifferential() -> Sutra {
        func phase(_ kind: PersonaJobKind, _ title: String,
                   _ obligations: [String], _ human: [String], _ prohibited: [String]) -> SutraPhase {
            let p = JobToolingCatalog.profile(for: kind)
            return SutraPhase(kind: kind, title: title,
                              tier: p?.tier ?? .capture, method: p?.method ?? .none, surface: p?.surface,
                              obligations: obligations, humanDecisions: human, prohibitedConclusions: prohibited)
        }
        let phases = [
            phase(.caseIntake, "Presenting complaint & scope",
                  ["Record the presenting complaint and relevant history"], ["Frame the clinical question"],
                  ["Anchor on the first diagnosis that comes to mind"]),
            phase(.dataLab, "Findings register",
                  ["Record labs, imaging and exam findings — each with its source"], [],
                  ["Record a finding without its source"]),
            phase(.analysis, "Differential diagnosis",
                  ["List candidate diagnoses as hypotheses", "Rate each finding for consistency — rule out by disconfirming",
                   "Rank by fewest inconsistencies"],
                  ["Record the leading diagnosis and a certainty"],
                  ["Rule a diagnosis out on absence of evidence alone", "Claim certainty the evidence doesn't support"]),
            phase(.contradictionGap, "Discrepant findings",
                  ["Preserve conflicting findings; reconcile each explicitly"], ["Reconcile each discrepancy"],
                  ["Ignore a discrepant result"]),
            phase(.methods, "Investigations plan",
                  ["Order tests that would discriminate the differential"], [],
                  ["Order tests that cannot change management"]),
            phase(.findings, "Assessment & plan",
                  ["State the working diagnosis with a certainty (GRADE)", "Surface unresolved findings"],
                  ["Sign off the assessment"],
                  ["Assert a diagnosis beyond the stated certainty"]),
            phase(.closure, "Disposition",
                  ["Record follow-up and safety-net advice"], ["Decide the disposition"],
                  ["Discharge with unresolved red-flag findings"])
        ]
        return Sutra(
            id: "sutra.clinical.differential", version: 1,
            title: "Clinical differential diagnosis",
            provenance: "Clinical reasoning framed as competing hypotheses — reuses the same ACH engine, the same conformance gates, and no new UI. Illustrative only; not medical advice.",
            reliabilityScale: "GRADE — certainty of evidence (High / Moderate / Low / Very low)",
            phases: phases,
            standardsOfProof: [],   // clinical certainty is GRADE, not a legal standard
            reportSections: ["Presenting complaint", "Findings", "Differential (ACH)",
                             "Assessment & certainty", "Plan & safety-net", "Sign-off"])
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
