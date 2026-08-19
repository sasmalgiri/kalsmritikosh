//
//  CompliancePersonaPackage.swift
//  Kalsmritikosh
//
//  Compliance / HR Investigator persona (owner request 2026-08-19,
//  buyer-research driven) — a LENS over the shared engines in the vocabulary
//  workplace and compliance investigations actually use: complaint,
//  allegation, complainant/respondent, balance of probabilities, findings
//  memo, corrective action. No forked engine; the "allegation ≠ proven"
//  discipline is the same claim-evidence contract the shared services carry.
//

import Foundation

public nonisolated enum CompliancePersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.compliance")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.compliance.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Compliance / HR Investigator",
            detail: "Run a workplace or compliance investigation that stands up later — allegations tracked, statements compared, evidence logged with custody, findings on the balance of probabilities, corrective actions to closure.")
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
    /// named in workplace-investigation working vocabulary.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "hr.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("complaint-intake", "Complaint intake",          "Open the case and set the authorized evidence scope.", .caseIntake),
            job("ask",              "Ask the case file",         "Ask a question over the case's documents — every answer cited.", .ask),
            job("allegations",      "Allegation worksheet",      "Frame each allegation (5W1H) — an allegation is unproven until found.", .analysis),
            job("parties",          "Party profiles",            "Profile complainant, respondent, and witnesses from cited evidence.", .subjectDossier),
            job("name-resolution",  "Name resolution",           "Confirm names and accounts belong to the same person (reversible).", .identityResolution),
            job("incident-timeline","Incident timeline",         "The incident chronology with relationship links, every event cited.", .linkage),
            job("evidence-register","Documentary evidence register", "Emails, records, and policies in a register with cited cells.", .dataLab),
            job("statements",       "Statement comparison",      "Compare accounts — conflicts preserved so due process holds.", .contradictionGap),
            job("credibility",      "Credibility assessment",    "Assess reliability and independence of each account (rating ≠ fact).", .sourceReliability),
            job("interview-prep",   "Interview preparation",     "Prepare interview questions over the cited record.", .methods),
            job("root-cause",       "Root-cause analysis",       "Why did it happen — Five Whys / Fishbone for systemic causes.", .causalAnalysis),
            job("evidence-custody", "Evidence log & custody",    "Chain-of-custody log for collected evidence with integrity hashes.", .evidenceCustody),
            job("findings-memo",    "Findings memo",             "Findings on the balance of probabilities, with a sealed receipt.", .findings),
            job("corrective-actions","Corrective actions",       "Track corrective and preventive actions to closure.", .capaRegister),
            job("action-review",    "Action effectiveness",      "Verify a completed action actually fixed the issue.", .effectivenessReview),
            job("closure",          "Close the case",            "Close or reopen the case by an explicit human decision.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
