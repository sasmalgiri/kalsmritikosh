//
//  Sutra.swift
//  Kalsmritikosh
//
//  Sūtra Engine — roadmap step 3 (see VISION_SUTRA_ENGINE.md). The doctrine made
//  first-class: a discipline's phases, each with its tier + method + obligations
//  + reserved human decisions + prohibited conclusions, plus its standards of
//  proof and report form. This is the constitution the app already follows,
//  assembled into one inspectable value — derived from JobToolingCatalog (tier /
//  method) and the recognized disciplines encoded across the app.
//
//  Pure value + a doctrine table; no behavior change. Read-only inspector in
//  SutraView.
//

import Foundation

public nonisolated struct SutraPhase: Sendable, Identifiable, Equatable, Codable {
    public var id: String { kind.rawValue }
    public let kind: PersonaJobKind
    public let title: String
    public let tier: PhaseTier
    public let method: AnalyticMethod
    public let surface: String?                 // Destination.rawValue, or nil (form/service)
    public let obligations: [String]            // what the phase must do
    public let humanDecisions: [String]         // reserved for a person (the ambiguity gate)
    public let prohibitedConclusions: [String]  // what it must never assert
}

/// One recorded change to a constitution: SOPs evolve, and the record of what
/// changed, when, and why must travel with the sutra — an unversioned,
/// unamendable constitution can't be complied with over time.
public nonisolated struct SutraAmendment: Sendable, Equatable, Codable {
    public let version: Int
    public let date: String        // yyyy-mm-dd
    public let summary: String     // what changed and why
    public init(version: Int, date: String, summary: String) {
        self.version = version; self.date = date; self.summary = summary
    }
}

public nonisolated struct Sutra: Sendable, Equatable, Codable {
    public let id: String
    public let version: Int
    public let title: String
    public let provenance: String
    public let reliabilityScale: String
    public let phases: [SutraPhase]
    public let standardsOfProof: [EvidentiaryStandard]
    public let reportSections: [String]
    /// Amendment history, oldest first. Optional so sutras recorded before
    /// governance existed still decode; nil reads as "v\(version), unamended".
    public var amendments: [SutraAmendment]? = nil
    /// Run-wide requirements that no single phase owns (e.g. "Every claim in the
    /// deliverable carries its evidence"). Optional so previously recorded sutras
    /// still decode; each line compiles to a mandatory GLOBAL typed rule.
    public var globalRequirements: [String]? = nil
    /// Phases a conformant run MUST reach. nil (legacy) reads as "the findings
    /// phase, when the sutra has one" — an unreached required phase FAILS its
    /// rules instead of marking them notApplicable.
    public var requiredPhaseKinds: [PersonaJobKind]? = nil

    /// Phases in tier order (the shape of the practice).
    public func phases(inTier tier: PhaseTier) -> [SutraPhase] { phases.filter { $0.tier == tier } }

    /// "Title v3 · sutra.id" — how certificates and reports cite this constitution.
    public var citation: String { "\(title) v\(version) · \(id)" }

    /// A new version of this sutra with the change recorded — the ONLY
    /// sanctioned way to alter a constitution: version bumps, history appends.
    public func amended(on date: String, summary: String,
                        phases newPhases: [SutraPhase]? = nil,
                        reportSections newSections: [String]? = nil) -> Sutra {
        var next = Sutra(id: id, version: version + 1, title: title,
                         provenance: provenance, reliabilityScale: reliabilityScale,
                         phases: newPhases ?? phases, standardsOfProof: standardsOfProof,
                         reportSections: newSections ?? reportSections)
        next.amendments = (amendments ?? []) + [SutraAmendment(version: version + 1, date: date, summary: summary)]
        next.globalRequirements = globalRequirements
        next.requiredPhaseKinds = requiredPhaseKinds
        return next
    }
}

/// The doctrine per job-kind — the obligations, reserved human decisions, and
/// prohibited conclusions the app already enforces, stated declaratively.
public nonisolated enum SutraDoctrine {

    public static func title(_ kind: PersonaJobKind) -> String {
        switch kind {
        case .caseIntake: return "Intake & scope"
        case .ask: return "Ask the evidence"
        case .methods: return "Professional methods"
        case .dataLab: return "Registers & tables"
        case .subjectDossier: return "Subject workup"
        case .identityResolution: return "Identity resolution"
        case .analysis: return "Competing hypotheses (ACH)"
        case .sourceReliability: return "Source reliability"
        case .contradictionGap: return "Contradictions & gaps"
        case .causalAnalysis: return "Causal analysis"
        case .linkage: return "Timeline & links"
        case .capaRegister: return "Corrective actions"
        case .effectivenessReview: return "Effectiveness review"
        case .evidenceCustody: return "Chain of custody"
        case .findings: return "Findings & report"
        case .closure: return "Closure"
        }
    }

    public static func doctrine(for kind: PersonaJobKind)
        -> (obligations: [String], humanDecisions: [String], prohibited: [String]) {
        switch kind {
        case .caseIntake:
            return (["Set the mandate and the authorized evidence scope"], ["Authorize the scope"], ["Investigate outside the authorized scope"])
        case .ask:
            return (["Answer only from cited evidence"], [], ["State an answer the evidence doesn't support"])
        case .methods:
            return (["Apply a recognized structured method"], [], ["Skip the method's steps"])
        case .dataLab:
            return (["Cite every row to a source document"], [], ["Enter a figure with no source"])
        case .subjectDossier:
            return (["Cite each fact to its source, within scope"], [], ["Assert unsourced background"])
        case .identityResolution:
            return (["Propose a merge, then confirm it (reversible)"], ["Confirm the merge"], ["Auto-merge without review"])
        case .analysis:
            return (["List every plausible hypothesis", "Rate each against the evidence — disprove, don't confirm", "Rank by fewest inconsistencies"],
                    ["Record the leading hypothesis and a confidence"],
                    ["Claim a computed verdict", "Overstate certainty when several hypotheses remain live"])
        case .sourceReliability:
            return (["Rate each source on the Admiralty scale (A–F × 1–6)"], [], ["Treat a reliability rating as a proven fact"])
        case .contradictionGap:
            return (["Preserve both sides of a conflict verbatim", "Record a disposition for each"], ["Dispose of each conflict"],
                    ["Average a conflict away", "Treat an absence of evidence as proof"])
        case .causalAnalysis:
            return (["Trace causes with evidence at each step (5 Whys / fishbone)"], ["Confirm the root cause"], ["Assert a root cause the evidence doesn't support"])
        case .linkage:
            return (["Cite each edge, event, and transaction"], [], ["Draw a link with no evidence"])
        case .capaRegister:
            return (["Track each corrective/preventive action to closure"], [], [])
        case .effectivenessReview:
            return (["Verify the action actually resolved the exposure"], ["Judge effectiveness"], ["Close an action that didn't work"])
        case .evidenceCustody:
            return (["Record custody contemporaneously", "Hash evidence as early as possible (SWGDE/NIST)"], [], ["Break the chain of custody silently"])
        case .findings:
            return (["Declare a standard of proof", "Surface every open contradiction and gap"], ["Approve the findings"],
                    ["Approve beyond the declared standard of proof", "Hide open conflicts at report time"])
        case .closure:
            return (["Record unresolved items honestly"], ["Decide to close or reopen"], ["Imply completeness when items remain open"])
        }
    }
}
