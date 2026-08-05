//
//  JournalistPersonaPackage.swift
//  Kalsmritikosh
//
//  Journalist persona — production identity + launchable jobs (JRN-01…JRN-14). A LENS over the shared engines
//  (matter scope, claim board, source map/reliability, quotes, chronology, fact verification, reporting gaps,
//  right of reply, publication decision, publication package). Every job maps to a persona-neutral
//  PersonaJobKind routed by PersonaJobService into a real shared service — no forked engine.
//
//  Human-only boundary: publication readiness is a human decision (never automated).
//

import Foundation

public nonisolated enum JournalistPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.journalist")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.journalist.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1, label: "Journalist",
            detail: "Story research and verification: sources, claims, quotes, chronology, fact-checking, and a publication package — every claim corroborated and cited; publication remains a human decision.")
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
            PersonaJob(persona: p, id: "jrn.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("story-intake",       "Story intake",           "Define the story question, scope, and authorized sources.", .caseIntake),
            job("claim-board",        "Claim board",            "Track claims and their verification status.", .analysis),
            job("source-map",         "Source map",             "Map sources, people, and relationships.", .linkage),
            job("source-reliability", "Source reliability",     "Assess source reliability and independence.", .sourceReliability),
            job("interview-plan",     "Interview plan",         "Identify reporting gaps to fill by interview.", .contradictionGap),
            job("quote-book",         "Quote book",             "Collect quotes cited to their exact source.", .analysis),
            job("transcript",         "Transcript correction",  "Correct transcripts with locators; unheard words never asserted.", .analysis),
            job("chronology",         "Chronology",             "Build the story timeline (undated labelled, cited).", .linkage),
            job("fact-verification",  "Fact verification",      "Verify claims; conflicting accounts preserved.", .contradictionGap),
            job("reporting-gap",      "Reporting-gap register", "Record unanswered questions (absence ≠ proof).", .contradictionGap),
            job("right-of-reply",     "Right of reply",         "Log subjects and their responses.", .subjectDossier),
            job("publication",        "Publication decision",   "Record the human publication decision (never automated).", .closure),
            job("correction-history", "Correction history",     "Track post-publication corrections.", .analysis),
            job("publication-package","Publication package",    "Assemble the verified publication package + sealed receipt.", .findings)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
