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

    /// STEP 5 (more) — safety-incident root-cause analysis, authored as a Sūtra.
    /// Its causal phase reuses the Reasoning Studio (5 Whys / fishbone).
    public static func safetyIncident() -> Sutra {
        let phases = [
            authored(.caseIntake, "Incident & scope",
                     ["Record what happened, when, where, and the immediate harm"], ["Set the investigation scope"],
                     ["Assign blame before the facts are in"]),
            authored(.dataLab, "Fact register",
                     ["Record the sequence of events and conditions — each sourced"], [],
                     ["State a cause as a fact in the register"]),
            authored(.causalAnalysis, "Root-cause analysis",
                     ["Trace contributing causes with evidence (5 Whys / fishbone)"], ["Confirm the root cause(s)"],
                     ["Stop at the first human error — look for the system cause"]),
            authored(.contradictionGap, "Conflicting accounts",
                     ["Preserve conflicting accounts; reconcile explicitly"], ["Reconcile each conflict"],
                     ["Average conflicting accounts into one story"]),
            authored(.capaRegister, "Corrective & preventive actions",
                     ["Define actions that remove the root cause, to closure"], [],
                     ["Close on a fix that only treats the symptom"]),
            authored(.effectivenessReview, "Effectiveness review",
                     ["Verify each action actually prevented recurrence"], ["Judge effectiveness"],
                     ["Close an action that didn't work"]),
            authored(.findings, "Incident report",
                     ["State causes and recommendations with the evidence", "Surface unresolved items"], ["Approve the report"],
                     ["Recommend beyond what the evidence supports"]),
            authored(.closure, "Closure",
                     ["Record residual risk honestly"], ["Decide to close or reopen"],
                     ["Imply the risk is eliminated when it's only reduced"])
        ]
        return Sutra(id: "sutra.safety.incident", version: 1, title: "Safety-incident RCA",
                     provenance: "Incident investigation — a just-culture root-cause analysis; reuses the Reasoning Studio (5 Whys / fishbone) and the same conformance gates.",
                     reliabilityScale: "Contributing-factor weighting (none / contributory / root)",
                     phases: phases, standardsOfProof: [],
                     reportSections: ["Incident summary", "Sequence of events", "Root causes",
                                      "Corrective & preventive actions", "Residual risk", "Sign-off"])
    }

    /// Systematic evidence review, authored as a Sūtra. Extraction rides the cited
    /// table; certainty is GRADE.
    public static func systematicReview() -> Sutra {
        let phases = [
            authored(.caseIntake, "Protocol & question",
                     ["Fix the review question and inclusion criteria before screening"], ["Register the protocol"],
                     ["Change the criteria to fit the result you want"]),
            authored(.dataLab, "Extraction table",
                     ["Screen at each PRISMA stage with reasons for exclusion", "Extract one row per included study, sourced"], [],
                     ["Include a study that fails the criteria"]),
            authored(.contradictionGap, "Discrepancies",
                     ["Preserve disagreeing studies; reconcile or explain heterogeneity"], ["Reconcile each discrepancy"],
                     ["Drop an inconvenient study without a reason"]),
            authored(.methods, "Synthesis method",
                     ["Apply the pre-registered synthesis method"], [],
                     ["Switch methods to reach a tidier answer"]),
            authored(.findings, "Synthesis & certainty",
                     ["State the synthesis with a GRADE certainty", "Surface the limitations"], ["Sign off the synthesis"],
                     ["Overstate certainty beyond the GRADE rating"]),
            authored(.closure, "Publish / archive",
                     ["Record open questions and update triggers"], ["Decide to publish or reopen"],
                     ["Present the review as final when evidence is still emerging"])
        ]
        return Sutra(id: "sutra.systematic.review", version: 1, title: "Systematic review",
                     provenance: "Evidence synthesis — PRISMA screening + GRADE certainty; reuses the cited-table engine and the same conformance gates.",
                     reliabilityScale: "GRADE — certainty of evidence (High / Moderate / Low / Very low)",
                     phases: phases, standardsOfProof: [],
                     reportSections: ["Question & protocol", "Screening (PRISMA)", "Extraction",
                                      "Synthesis (GRADE)", "Limitations", "Sign-off"])
    }

    private static func authored(_ kind: PersonaJobKind, _ title: String,
                                 _ obligations: [String], _ human: [String], _ prohibited: [String]) -> SutraPhase {
        let p = JobToolingCatalog.profile(for: kind)
        return SutraPhase(kind: kind, title: title, tier: p?.tier ?? .capture, method: p?.method ?? .none,
                          surface: p?.surface, obligations: obligations, humanDecisions: human, prohibitedConclusions: prohibited)
    }

    /// The built-in disciplines — proof that one engine serves many subjects.
    public static var builtInDisciplines: [(id: String, label: String, sutra: Sutra)] {
        [("investigation", "Investigation", shared()),
         ("clinical", "Clinical differential", clinicalDifferential()),
         ("safety", "Safety incident", safetyIncident()),
         ("review", "Systematic review", systematicReview())]
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
