//
//  GenealogistPersonaPackage.swift
//  Kalsmritikosh
//
//  Genealogist / Family Historian persona (owner request 2026-08-19,
//  buyer-research driven) — a LENS over the shared engines in the vocabulary
//  of the Genealogical Proof Standard (GPS): research log, source citations,
//  original vs derivative sources, conflicting-evidence resolution, proof
//  argument. The GPS's five elements map one-to-one onto disciplines the
//  shared services already enforce (exhaustive scope, citations that reopen,
//  correlation, conflict resolution, written cited conclusion).
//

import Foundation

public nonisolated enum GenealogistPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.genealogist")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.genealogist.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Genealogist / Family Historian",
            detail: "Research your family to the Genealogical Proof Standard — a research log with citations that reopen their source, ancestor profiles, conflicting records resolved (never averaged), and a written proof argument.")
    }

    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(
            id: terminologyID, version: 1, applicationID: applicationID,
            labels: [.claim: "Fact"])
    }

    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    /// Full 16-kind coverage — one launchable job per shared capability,
    /// named in GPS working vocabulary.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "gen.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("research-plan",   "Research question & plan",  "Fix the research question and the record scope before searching.", .caseIntake),
            job("ask",             "Ask the family records",    "Ask a question over your records — every answer cites its document.", .ask),
            job("research-log",    "Research log",              "The classic research log — what was searched, where, what it yielded.", .dataLab),
            job("ancestor-profile","Ancestor profile",          "Everything known about one ancestor, each fact cited.", .subjectDossier),
            job("same-person",     "Same person?",              "Resolve name variants to one person (reversible, you decide).", .identityResolution),
            job("family-lines",    "Family lines & timeline",   "Family relationships and life timelines, every event cited.", .linkage),
            job("conflicts",       "Conflicting evidence",      "Resolve records that disagree — both kept on file (GPS element 4).", .contradictionGap),
            job("source-analysis", "Source analysis",           "Original or derivative? Primary or secondary information? (rating ≠ fact).", .sourceReliability),
            job("evidence-notes",  "Evidence correlation",      "Correlate evidence across records (5W1H worksheets).", .analysis),
            job("methods",         "Guided methods",            "Structured checklists for reasonably exhaustive research.", .methods),
            job("migration",       "Why did they move?",        "Trace causes — migration, name changes — step by step over cited records.", .causalAnalysis),
            job("originals",       "Source citations & originals", "Custody-tracked originals; every citation reopens its exact source.", .evidenceCustody),
            job("proof-argument",  "Proof argument (GPS)",      "The written, soundly-reasoned conclusion with a sealed receipt.", .findings),
            job("to-do",           "Research to-dos",           "Track follow-up searches and record orders to closure.", .capaRegister),
            job("to-do-review",    "Did it answer?",            "Verify a completed search actually answered the question.", .effectivenessReview),
            job("close-question",  "Close the question",        "Close or reopen the research question by explicit decision.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
