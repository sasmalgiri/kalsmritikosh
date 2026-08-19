//
//  ForensicAccountantPersonaPackage.swift
//  Kalsmritikosh
//
//  Forensic Accountant persona (owner request 2026-08-19, buyer-research
//  driven) — a LENS over the shared engines in the vocabulary forensic
//  accountants actually use: engagement, funds tracing, tracing schedules,
//  workpapers, expert report. Tracing schedules ride the shared DataLab;
//  funds flow rides the shared transaction-flow linkage; workpapers ride
//  the shared custody vault. No forked engine.
//

import Foundation

public nonisolated enum ForensicAccountantPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.forensicaccountant")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.forensicaccountant.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Forensic Accountant",
            detail: "Follow the money through your records — funds tracing, tracing schedules with cited cells, discrepancy analysis, and an exhibit-ready expert report — every amount drills to its source document.")
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
    /// named in forensic-accounting working vocabulary.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "fa.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("engagement",       "Engagement intake",        "Open the engagement and set the authorized records scope.", .caseIntake),
            job("ask",              "Ask the records",          "Ask a question over the engagement's records — every answer cited.", .ask),
            job("funds-tracing",    "Funds tracing & flow",     "Follow the money — transaction flow, timelines, and relationship links.", .linkage),
            job("tracing-schedule", "Tracing schedules",        "Build tracing schedules (payments, transfers) — every cell cites its source.", .dataLab),
            job("payee-workup",     "Payee / entity workup",    "Work up a payee, vendor, or counterparty, citing exact in-scope evidence.", .subjectDossier),
            job("entity-resolution","Entity & alias resolution","Resolve shell names and aliases to one entity (reversible, human-gated).", .identityResolution),
            job("discrepancies",    "Discrepancies & missing records", "Where the records disagree or are absent (absence ≠ proof).", .contradictionGap),
            job("doc-reliability",  "Record reliability",       "Assess origin and reliability of ledgers, invoices, and statements.", .sourceReliability),
            job("analysis",         "Analysis worksheet",       "Hypotheses, 5W1H, and the evidence plan for the engagement.", .analysis),
            job("methods",          "Method workbench",         "Run structured methods over the engagement's cited record.", .methods),
            job("root-cause",       "Root-cause analysis",      "Trace how the loss or misstatement occurred — Five Whys / Fishbone.", .causalAnalysis),
            job("workpapers",       "Workpapers & custody",     "The workpaper vault — custody-tracked originals with integrity hashes.", .evidenceCustody),
            job("expert-report",    "Expert report & exhibits", "Assemble the expert report with cited exhibits and a sealed receipt.", .findings),
            job("recovery",         "Recovery actions",         "Track recovery and remediation actions to closure.", .capaRegister),
            job("recovery-review",  "Recovery effectiveness",   "Verify a completed action actually recovered or remediated.", .effectivenessReview),
            job("closure",          "Close the engagement",     "Close or reopen the engagement by an explicit human decision.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
