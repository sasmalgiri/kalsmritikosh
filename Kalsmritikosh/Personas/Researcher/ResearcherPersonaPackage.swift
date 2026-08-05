//
//  ResearcherPersonaPackage.swift
//  Kalsmritikosh
//
//  Researcher / Historian persona — the ONE source of truth for the persona's production identity and its
//  launchable jobs (RES-01…RES-14, per PERSONA_JOB_COVERAGE_MATRIX.csv). Like the Investigator, the Researcher
//  is a LENS over the shared engines: each job maps to a persona-neutral PersonaJobKind that PersonaJobService
//  already routes into a real shared service (matter scope, DataLab, entity authority, source reliability,
//  timeline/relationship methods, contradiction/interpretation desk, custody/citation audit, findings/edition).
//  No forked engine, no persona-specific Claim/Method/Workbench store — the `Investigation*` case-scoped
//  services are the shared matter engine and are reused verbatim.
//
//  Truth boundaries carried by the jobs' underlying services: interpretation ≠ fact; reconstruction ≠
//  certainty; both competing accounts preserved; a scenario never mutates the ledger; every cite reopens its
//  source; report == receipt.
//

import Foundation

public nonisolated enum ResearcherPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.researcher")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.researcher.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Researcher / Historian",
            detail: "Evidence-bounded research and historical reconstruction: matter + corpus, chronology, competing interpretations, and annotated editions — every finding cited, every interpretation kept distinct from fact.")
    }

    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(
            id: terminologyID, version: 1, applicationID: applicationID,
            labels: [.claim: "Finding"])
    }

    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    /// RES-01…RES-14 mapped to persona-neutral PersonaJobKinds routed by PersonaJobService into shared
    /// services. Several research jobs legitimately share a kind (they are different surfaces over the same
    /// shared capability); `id` is the unique key.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "res.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("protocol",           "Research protocol",            "Define the research question, scope, and authorized corpus.", .caseIntake),
            job("corpus-catalogue",   "Corpus catalogue",             "Catalogue every authorized source with provenance.", .dataLab),
            job("metadata",           "Metadata",                     "Record structured metadata per source, cited to the source.", .dataLab),
            job("transcription",      "Transcription & coding",       "Code passages into structured findings with locators.", .analysis),
            job("authority-control",  "Authority control",            "Unify names/terms to canonical authorities (reversible, human-reviewed).", .identityResolution),
            job("source-criticism",   "Source criticism",             "Assess origin, bias, and reliability of sources.", .sourceReliability),
            job("screening",          "Literature screening",         "Screen documents in/out by recorded, reversible criteria.", .analysis),
            job("extraction",         "Extraction & coding",          "Extract coded findings, each citing an evidence block.", .analysis),
            job("chronology",         "Chronology & periodisation",   "Build a periodised timeline (undated labelled, cited).", .linkage),
            job("prosopography",      "Prosopography",                "Compile a collective biography of a group, each cell cited.", .subjectDossier),
            job("interpretation",     "Interpretation comparison",    "Compare competing interpretations — both accounts preserved.", .contradictionGap),
            job("alternative",        "Alternative histories",        "Explore evidence-bounded counterfactuals (never mutates the ledger).", .dataLab),
            job("bibliography",       "Bibliography & citation audit", "Verify every citation reopens its exact source.", .evidenceCustody),
            job("edition",            "Annotated edition",            "Assemble an annotated edition/report with a sealed receipt.", .findings)
        ]
    }

    /// Register the Researcher application, terminology, and package into a catalog builder.
    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
