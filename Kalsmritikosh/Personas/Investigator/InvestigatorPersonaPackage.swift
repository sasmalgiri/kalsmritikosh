//
//  InvestigatorPersonaPackage.swift
//  Kalsmritikosh
//
//  #142 — the Investigator persona's REAL application package + its launchable job list. This is the ONE
//  source of truth registered into the production PersonaJobCatalog so the persona is discoverable, and the
//  ONE list the live consumer enumerates. The jobs are POINTERS to the already-shipped Investigator services
//  (INV-01…INV-20) — the package declares no workflow definitions, because the Investigator's jobs are
//  concrete case-scoped services, not the generic PJE workflow-definition model. Registering empty
//  tool/workflow sets is deliberate and honest: it anchors the persona in production without fabricating a
//  parallel workflow surface.
//

import Foundation

public nonisolated enum InvestigatorPersonaPackage {

    /// The Investigator application's stable production identity.
    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.investigator")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.investigator.terminology")

    /// The persona application registered in the production catalog. Empty tool/workflow sets — the persona's
    /// jobs are concrete services enumerated via `jobs`, not generic workflow definitions.
    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1,
            label: "Investigator",
            detail: "Case-scoped investigation: intake & scope, evidence, methods, findings, and closure — every job bounded to the case's authorized evidence.")
    }

    /// The persona's terminology (minimal, application-matched — required by the catalog builder).
    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(
            id: terminologyID, version: 1, applicationID: applicationID,
            labels: [.claim: "Finding"])
    }

    /// The resolvable application package (terminology only — no fabricated schemas/workflows/validators).
    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    /// The persona's REAL jobs, in workflow order (INV-01…INV-20). Each routes to a shipped service.
    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "inv.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("case-intake",           "Case intake & scope",      "Create a case and set its authorized evidence scope.", .caseIntake),
            job("ask",                   "Ask (case-scoped)",        "Answer a question over the case's authorized evidence only.", .ask),
            job("methods",               "Professional methods",     "Run a professional method over case-authorized evidence.", .methods),
            job("data-lab",              "DataLab",                  "Prepare authorized-only datasets over the shared Workbench.", .dataLab),
            job("subject-dossier",       "Subject workup",           "Work up a subject — the background dossier, citing exact in-scope evidence.", .subjectDossier),
            job("identity-resolution",   "Identity resolution",      "Resolve identity via the shared reversible merge, human-gated.", .identityResolution),
            job("analysis",              "Analysis worksheet",       "Brainstorm, 5W1H, evidence plan, and hypothesis matrix.", .analysis),
            job("source-reliability",    "Source reliability",       "Assess case source reliability (rating ≠ fact).", .sourceReliability),
            job("contradiction-gap",     "Contradiction & gap desk", "Review in-scope contradictions and gaps (absence ≠ proof).", .contradictionGap),
            job("causal-analysis",       "Causal analysis",          "Five Whys / Fishbone / Root-cause over the shared method engine.", .causalAnalysis),
            job("linkage",               "Timeline & link analysis", "Timeline, link chart (people–objects–locations–events), and transaction/asset flow.", .linkage),
            job("capa-register",         "CAPA register",            "Corrective/preventive action register (human-closed).", .capaRegister),
            job("effectiveness-review",  "Effectiveness review",     "Review CAPA effectiveness (human decision required).", .effectivenessReview),
            job("evidence-custody",      "Chain of custody",         "The evidence locker — the case custody manifest over authorized versions.", .evidenceCustody),
            job("findings",              "Case report & export",     "Assemble the case report — findings with a sealed receipt.", .findings),
            job("closure",              "Closure & reopen",          "Close or reopen the case by an explicit human decision.", .closure)
        ]
    }

    /// Register the Investigator application, terminology, and package into a catalog builder.
    /// This is the ONLY place the Investigator package is registered for production.
    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
