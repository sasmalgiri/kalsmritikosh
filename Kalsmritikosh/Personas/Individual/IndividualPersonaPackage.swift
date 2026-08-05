//
//  IndividualPersonaPackage.swift
//  Kalsmritikosh
//
//  Individual persona — production identity + launchable jobs (IND-01…IND-13). A LENS over the shared engines
//  for a non-technical user: personal records, document versions, chronology, family/property/insurance
//  registers, reminders, and shareable packages. Every job maps to a persona-neutral PersonaJobKind routed by
//  PersonaJobService into a real shared service. This persona optimizes for a zero-learning Simple experience;
//  the internal vocabulary is never required of the user.
//

import Foundation

public nonisolated enum IndividualPersonaPackage {

    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.persona.individual")
    public static let terminologyID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.persona.individual.terminology")

    public static var application: PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: applicationID, version: 1, label: "Individual",
            detail: "Organize your personal documents, records, and important dates — find what matters, see what changed, and prepare shareable packages, all in plain language.")
    }
    public static var terminology: PersonaTerminologyDefinition {
        PersonaTerminologyDefinition(id: terminologyID, version: 1, applicationID: applicationID, labels: [.claim: "Fact"])
    }
    public static var package: PersonaApplicationPackageDefinition {
        PersonaApplicationPackageDefinition(application: application, terminologyID: terminologyID)
    }

    public static var jobs: [PersonaJob] {
        let p = applicationID.rawValue
        func job(_ id: String, _ title: String, _ detail: String, _ kind: PersonaJobKind) -> PersonaJob {
            PersonaJob(persona: p, id: "ind.\(id)", title: title, detail: detail, kind: kind)
        }
        return [
            job("personal-records",   "Personal records",         "Bring in and organize your documents and records.", .caseIntake),
            job("document-versions",  "Official-document versions","Track versions of official documents.", .dataLab),
            job("career-education",    "Career & education",       "Summarize your career and education over time.", .linkage),
            job("family-records",      "Family records",           "Organize family members and relationships.", .subjectDossier),
            job("property",            "Property",                 "Keep a register of property and assets.", .dataLab),
            job("insurance",           "Insurance",                "Keep a register of insurance policies.", .dataLab),
            job("health-scope",        "Health-record scope",      "Summarize health records you choose to include.", .analysis),
            job("applications",        "Applications & cases",     "Track applications and open cases.", .analysis),
            job("reminders",           "Confirmed reminders",      "Keep a list of confirmed important dates.", .analysis),
            job("emergency-pack",      "Emergency pack",           "Assemble an emergency information package.", .findings),
            job("secure-share",        "Secure share / redaction", "Prepare a redacted package to share safely.", .findings),
            job("personal-chronology", "Personal chronology",      "See your personal timeline (undated labelled).", .linkage),
            job("legacy-archive",      "Legacy archive",           "Assemble a legacy archive with a sealed receipt.", .findings)
        ]
    }

    public static func register(into builder: inout PersonaJobCatalogBuilder) throws {
        try builder.registerApplication(application)
        try builder.registerTerminology(terminology)
        builder.registerPackage(package)
    }
}
