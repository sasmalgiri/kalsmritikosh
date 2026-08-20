//
//  ContentCreatorPersonaPackage.swift
//  Kalsmritikosh
//
//  Content Creator persona (owner request 2026-08-20) — a LENS over the
//  shared engines in the vocabulary independent creators actually use:
//  content project, angle, guest/subject, source vetting, fact-check, rights
//  cleared, publish package. No forked engine; every job maps to a
//  persona-neutral PersonaJobKind routed by PersonaJobService into the same
//  shared services the Investigator and Journalist use.
//
//  Distinct from the Journalist (whose job is verification-for-publication
//  under legal risk): the creator's job is a steady, researched content
//  pipeline. The truth boundary is the same one the shared services carry —
//  a claim is a cited FACT or it isn't published as one; sources are vetted
//  for reliability; conflicting accounts are shown, never averaged.
//

import Foundation

public nonisolated enum ContentCreatorPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.contentcreator")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.contentcreator.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Content Creator",
            detail: "Research a video, article, podcast, or newsletter end to end — gather sources, vet them, fact-check every claim, vet guests, and assemble a cited, rights-cleared package — so what you publish holds up and you can show your work.")
    }

    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(
            id: terminologyID, version: 1, applicationID: applicationID,
            labels: [.claim: "Fact", .report: "Content package", .subject: "Guest / subject"])
    }

    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    /// Full 16-kind coverage — one launchable job per shared capability,
    /// named in a content creator's working vocabulary.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "cc.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("project-intake",  "Start a content project",   "Open the project and set which sources it may draw on.", .caseIntake),
            job("ask",             "Ask your research",         "Ask a question across the project's sources — every answer cited.", .ask),
            job("angle",           "Angle & outline",           "Shape the hook and outline (5W1H) from what the sources actually support.", .analysis),
            job("script-prep",     "Script / interview prep",   "Draft interview questions and talking points over the cited record.", .methods),
            job("guest-workup",    "Guest / subject background", "Background a guest or subject before you feature them, citing exact evidence.", .subjectDossier),
            job("identity",        "Confirm who's who",         "Confirm names, handles, and entities are the same party (reversible, human-gated).", .identityResolution),
            job("research-table",  "Research table",            "Build a data-backed table for the piece — every cell drills to its source.", .dataLab),
            job("timeline",        "Timeline & connections",    "The story's timeline and how the people and orgs connect.", .linkage),
            job("fact-check",      "Fact-check board",          "Check each claim against evidence — conflicting accounts preserved, never averaged.", .contradictionGap),
            job("source-vetting",  "Source vetting",            "Assess how reliable and independent each source is before you rely on it.", .sourceReliability),
            job("explainer",       "Explainer: why it happened","Trace how something came about — Five Whys / Fishbone over cited evidence.", .causalAnalysis),
            job("rights-locker",   "Source & rights locker",    "Keep sources and clips with integrity hashes and their rights/clearance status.", .evidenceCustody),
            job("publish-package", "Publish package & export",  "Assemble the cited, rights-cleared package and export it (Word / PDF).", .findings),
            job("corrections",     "Corrections & follow-ups",  "Track corrections, rights clearances, and follow-ups through to done.", .capaRegister),
            job("performance",     "Post-publish review",       "Verify a correction or clearance actually resolved the issue it was for.", .effectivenessReview),
            job("wrap",            "Archive / wrap the project","Close or reopen the project by an explicit human decision.", .closure)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
