//
//  SIUPersonaPackage.swift
//  Kalsmritikosh
//
//  Insurance Fraud / SIU persona (owner request 2026-08-19, buyer-research
//  driven) — a LENS over the shared engines in the vocabulary insurance
//  Special Investigations Units actually use: claim file, red flags,
//  referral, examination under oath, loss chronology. No forked engine;
//  every job maps to a persona-neutral PersonaJobKind routed by
//  PersonaJobService into the same shared services the Investigator uses.
//
//  Truth boundary the vocabulary itself enforces: red flags are INDICATORS,
//  never proof — the same "rating ≠ fact" discipline the shared services
//  already carry.
//

import Foundation

public nonisolated enum SIUPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.siu")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.siu.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Insurance Fraud (SIU)",
            detail: "Work a referred claim file end to end — red-flag screening, claimant workup, loss chronology, statement comparison, and a defensible SIU report — every finding cited, every red flag an indicator, never proof.")
    }

    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(
            id: terminologyID, version: 1, applicationID: applicationID,
            labels: [.claim: "Finding"])
    }

    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    /// Full 16-kind coverage — one launchable job per shared capability,
    /// named in SIU working vocabulary.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "siu.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("claim-intake",     "Claim file intake",         "Open the claim file and set the authorized document scope.", .caseIntake),
            job("ask",              "Ask the claim file",        "Ask a question over the claim's documents — every answer cited.", .ask),
            job("red-flags",        "Red-flag worksheet",        "Record fraud indicators (5W1H) — red flags are indicators, never proof.", .analysis),
            job("claimant-workup",  "Claimant workup",           "The claimant/provider background workup, citing exact in-scope evidence.", .subjectDossier),
            job("identity",         "Identity resolution",       "Confirm names, aliases, and entities are the same party (reversible, human-gated).", .identityResolution),
            job("loss-chronology",  "Loss chronology & links",   "The loss timeline, relationship links, and payment flow.", .linkage),
            job("prior-claims",     "Prior-claims register",     "A register of prior/related claims with cited cells.", .dataLab),
            job("statements",       "Statement comparison",      "Compare statements — conflicting accounts preserved, never averaged.", .contradictionGap),
            job("source-vetting",   "Source vetting",            "Assess reliability and independence of statements and documents.", .sourceReliability),
            job("euo-prep",         "EUO / interview prep",      "Prepare examination-under-oath questions over the cited record.", .methods),
            job("causation",        "Causation analysis",        "Trace how the loss occurred — Five Whys / Fishbone over cited evidence.", .causalAnalysis),
            job("custody",          "Chain of custody",          "The claim evidence locker — custody manifest with integrity hashes.", .evidenceCustody),
            job("referral-report",  "SIU report & referral",     "Assemble the referral-ready SIU report with a sealed receipt.", .findings),
            job("recovery-actions", "Recovery & referral actions","Track recovery, NICB/DOI referral, and follow-up actions to closure.", .capaRegister),
            job("action-review",    "Action effectiveness",      "Verify a completed action actually resolved the exposure.", .effectivenessReview),
            job("closure",          "Close the claim file",      "Close or reopen the file by an explicit human decision.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
