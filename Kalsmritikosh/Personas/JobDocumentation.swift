//
//  JobDocumentation.swift
//  Kalsmritikosh
//
//  JOB-DOC (SAP-inspired job documentation) — the human-readable "what this
//  job does / needs / produces / must NOT conclude" record for each persona
//  job. SAP job/transaction documentation pairs an executable step with a
//  structured description (purpose, inputs, outputs, authorizations,
//  constraints); this brings the same idea to the persona job engine so the
//  71 launchable jobs are self-describing in the UI, not just runnable.
//
//  The authoritative data lives in PERSONA_JOB_COVERAGE_MATRIX.csv (the
//  governance document). The generated catalog below is compiled from that
//  CSV by scripts/generate-job-docs.sh; JobDocumentationDriftTests re-parses
//  the CSV and fails if the catalog drifts, so the two can never disagree.
//

import Foundation

/// Structured, persona-neutral documentation for one persona job. Presentation
/// only — it never carries evidence, confidence, or truth state (T1 invariant).
public struct JobDocumentation: Sendable, Equatable, Identifiable {
    public let jobID: String            // e.g. "INV-01" (matches the coverage matrix JobID)
    public let persona: String          // "Investigator" | "Researcher" | …
    public let name: String
    public let workflow: String         // the steps, in order
    public let requiredInputs: [String]
    public let methods: [String]        // professional methods this job may use
    public let workProducts: [String]   // what it produces
    public let humanDecisions: [String] // the human-in-the-loop gates
    public let prohibitedConclusions: [String] // what the job must NOT assert (the guardrails)

    public var id: String { jobID }

    public init(jobID: String, persona: String, name: String, workflow: String,
                requiredInputs: [String], methods: [String], workProducts: [String],
                humanDecisions: [String], prohibitedConclusions: [String]) {
        self.jobID = jobID; self.persona = persona; self.name = name; self.workflow = workflow
        self.requiredInputs = requiredInputs; self.methods = methods; self.workProducts = workProducts
        self.humanDecisions = humanDecisions; self.prohibitedConclusions = prohibitedConclusions
    }
}

public enum JobDocumentationCatalog {
    /// Documentation for a job by its coverage-matrix JobID (e.g. "INV-01").
    public static func doc(forJobID jobID: String) -> JobDocumentation? {
        byID[jobID.uppercased()]
    }

    /// All documented jobs for a persona label ("Investigator", …), matrix order.
    public static func docs(forPersona persona: String) -> [JobDocumentation] {
        all.filter { $0.persona.caseInsensitiveCompare(persona) == .orderedSame }
    }

    /// Bridge from a launchable PersonaJob to its matrix documentation by
    /// (persona label, job title / JobName). PersonaJob ids are engine-scoped
    /// (e.g. "inv.caseIntake") while the matrix keys on JobID (INV-01); the
    /// stable human bridge is the persona + the job's display title.
    public static func doc(personaLabel: String, jobTitle: String) -> JobDocumentation? {
        docs(forPersona: personaLabel).first {
            $0.name.caseInsensitiveCompare(jobTitle) == .orderedSame
        }
    }

    private static let byID: [String: JobDocumentation] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.jobID.uppercased(), $0) })

    // GENERATED from PERSONA_JOB_COVERAGE_MATRIX.csv by scripts/generate-job-docs.sh.
    // Do not hand-edit; edit the CSV and regenerate (JobDocumentationDriftTests enforces parity).
    public static let all: [JobDocumentation] = JobDocumentationGenerated.all
}
