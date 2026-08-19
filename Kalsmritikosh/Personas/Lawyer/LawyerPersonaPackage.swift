//
//  LawyerPersonaPackage.swift
//  Kalsmritikosh
//
//  Lawyer / Professional Reviewer persona — production identity + launchable jobs (LAW-01…LAW-14). A LENS over
//  the shared engines with the STRICTEST scope / review gates: matter scope, parties & issues, fact
//  chronology, fact–evidence matrix, witness profiles, document coding, privilege candidates, obligations,
//  damages, deadlines, deposition outline, exhibit binder, production, and redaction validation. Every job
//  maps to a persona-neutral PersonaJobKind routed by PersonaJobService into a real shared service.
//
//  Human-only boundaries (never automated — enforced by the shared human-gated services): privilege is never
//  auto-established (LAW-07 records candidates; a human decides); a deadline is a CANDIDATE until confirmed
//  (LAW-10); legal liability / legal conclusion / matter closure are human decisions. Production is
//  report==receipt with custody hashes (LAW-13). Both sides of a fact-evidence conflict are preserved (LAW-04).
//

import Foundation

public nonisolated enum LawyerPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.lawyer")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.lawyer.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1, label: "Lawyer / Professional Reviewer",
            detail: "Privilege-sensitive matter review: parties & issues, facts & evidence, obligations & deadlines, exhibits, and a production package — privilege, liability, and closure remain human decisions.")
    }
    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(id: terminologyID, version: 1, applicationID: applicationID, labels: [.claim: "Finding"])
    }
    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "law.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("matter-intake",     "Matter intake",              "Open the matter and set its authorized, privilege-sensitive scope.", .caseIntake),
            job("parties-issues",    "Parties & issues",           "Identify parties and issues linked to canonical objects.", .subjectDossier),
            job("fact-chronology",   "Case chronology",            "Build the case chronology — the spine of the matter (undated labelled, each fact cited).", .linkage),
            job("fact-evidence",     "Fact–evidence matrix",       "Map facts to evidence — both sides preserved, cites reopen.", .contradictionGap),
            job("witness-profiles",  "Witness profiles",           "Profile witnesses; contradictions cite both sides.", .subjectDossier),
            job("document-coding",   "Document coding",            "Code documents by recorded, reversible decisions.", .analysis),
            job("privilege",         "Privilege log",              "Build the privilege log — candidates recorded with basis; privilege is NEVER auto-established.", .analysis),
            job("obligations",       "Obligations & clauses",      "Compare obligations/clauses, each cell citing a clause locator.", .dataLab),
            job("damages",           "Damages ledger",             "Build a damages ledger; amounts cite source cells.", .dataLab),
            job("deadlines",         "Deadlines",                  "Track deadlines — a candidate until a human confirms it.", .analysis),
            job("deposition",        "Deposition outline",         "Draft a deposition outline; questions cite the record.", .analysis),
            job("exhibit-binder",    "Exhibit list & binder",      "Assemble the exhibit list and trial binder; each exhibit cites its source version.", .evidenceCustody),
            job("production",        "Document production",        "Produce the export set — every document carries a Bates-style number; report == receipt with custody hashes.", .findings),
            job("redaction",         "Redaction validation",       "Validate text + visual redaction before production.", .findings),
            // PJOB-MAX — full 16-kind coverage: the remaining shared capabilities
            // surfaced with matter framing. Same persona-neutral router, no fork.
            job("ask",               "Ask the case file",          "Ask a question over the matter's record — every claim cited.", .ask),
            job("methods",           "Method workbench",           "Run structured methods (5W1H, hypothesis matrix…) over the matter.", .methods),
            job("party-resolution",  "Party & alias resolution",   "Unify party names and aliases (reversible, human-reviewed).", .identityResolution),
            job("source-desk",       "Source reliability desk",    "Assess reliability and independence of record sources.", .sourceReliability),
            job("causation",         "Causation analysis",         "Trace causation step by step — Five Whys / Fishbone over the record.", .causalAnalysis),
            job("remediation",       "Remediation register",       "Track remediation/undertaking actions to closure.", .capaRegister),
            job("remediation-review","Remediation effectiveness",  "Verify a completed remediation actually resolved the issue.", .effectivenessReview),
            job("matter-closure",    "Matter closure & reopen",    "Close the matter (sealed); reopen preserves full history.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
