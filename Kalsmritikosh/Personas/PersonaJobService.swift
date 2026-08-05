//
//  PersonaJobService.swift
//  Kalsmritikosh
//
//  #142 — the ONE live consumer of the production PersonaJobCatalog. It closes the test-only-catalog gap: a
//  real component that (1) DISCOVERS a persona from the production catalog, (2) ENUMERATES that persona's real
//  jobs, and (3) ROUTES a selected job into its REAL implementation — the already-shipped Investigator
//  services. The router is an EXPLICIT per-kind dispatch (not a uniform stub): every branch calls a real,
//  case-scoped service method and returns the real outcome. Jobs whose backing engine is not booted in this
//  build fail closed with `serviceUnavailable` — an honest signal, never a fabricated success.
//

import Foundation

public actor PersonaJobService {
    private let catalog: PersonaJobCatalog

    // The REAL Investigator services this consumer routes into. Optional == not wired in this build (the job
    // enumerates but its launch fails closed). Injected from AppState's single boot.
    private let cases: InvestigationCaseRepository?
    private let answers: InvestigationAnswerService?
    private let subjectDossier: InvestigationSubjectDossierService?
    private let identityResolution: InvestigationIdentityResolutionService?
    private let analysis: InvestigationAnalysisService?
    private let reliability: InvestigationReliabilityService?
    private let contradictionGap: InvestigationContradictionGapService?
    private let custody: InvestigationCustodyService?
    private let closure: InvestigationClosureService?
    private let findings: InvestigationFindingsService?
    private let dataLab: InvestigationDataLabService?

    public init(catalog: PersonaJobCatalog,
                cases: InvestigationCaseRepository?,
                answers: InvestigationAnswerService?,
                subjectDossier: InvestigationSubjectDossierService?,
                identityResolution: InvestigationIdentityResolutionService?,
                analysis: InvestigationAnalysisService?,
                reliability: InvestigationReliabilityService?,
                contradictionGap: InvestigationContradictionGapService?,
                custody: InvestigationCustodyService?,
                closure: InvestigationClosureService?,
                findings: InvestigationFindingsService?,
                dataLab: InvestigationDataLabService?) {
        self.catalog = catalog
        self.cases = cases; self.answers = answers; self.subjectDossier = subjectDossier
        self.identityResolution = identityResolution; self.analysis = analysis; self.reliability = reliability
        self.contradictionGap = contradictionGap; self.custody = custody; self.closure = closure
        self.findings = findings; self.dataLab = dataLab
    }

    // MARK: - Discovery

    /// Every persona present in the production catalog (discoverable). Deterministic order.
    public func personas() -> [PersonaApplicationDefinition] { catalog.allApplications }

    /// Enumerate one persona's REAL jobs. Empty if the persona is not in the production catalog (never
    /// enumerates jobs for a persona the catalog does not carry — discovery and enumeration cannot diverge).
    public func jobs(forPersona applicationID: ApplicationDefinitionID) -> [PersonaJob] {
        guard catalog.latestApplication(id: applicationID) != nil else { return [] }
        return PersonaJobCatalogComposer.jobs(forPersona: applicationID)
    }

    // MARK: - Routing (into the real implementation)

    /// Route a selected job into its persona's real service. Verifies the persona is discoverable and the job
    /// is one the persona actually declares, then dispatches by kind to the real implementation.
    @discardableResult
    public func launch(_ job: PersonaJob, context: PersonaJobLaunchContext) async throws -> PersonaJobLaunch {
        let appID = ApplicationDefinitionID(rawValue: job.persona)
        guard catalog.latestApplication(id: appID) != nil else { throw PersonaJobError.unknownPersona(job.persona) }
        guard jobs(forPersona: appID).contains(where: { $0.id == job.id && $0.kind == job.kind }) else {
            throw PersonaJobError.unknownJob(job.id)
        }
        switch job.kind {

        case .caseIntake:
            guard let cases else { throw PersonaJobError.serviceUnavailable(.caseIntake) }
            if let ws = context.workspaceID, let title = context.title {
                let c = try await cases.createCase(workspaceID: ws, title: title, actor: context.actor, at: context.at)
                return PersonaJobLaunch(job: job, summary: "Created case \"\(title)\" (rev \(c.revision))", producedID: c.id)
            }
            let caseID = try requireCase(context)
            guard let record = try await cases.fetch(caseID: caseID) else { throw PersonaJobError.missingContext("case not found") }
            return PersonaJobLaunch(job: job, summary: "Case \"\(record.caseHeader.title)\" — status \(record.caseHeader.status.rawValue)", producedID: caseID)

        case .ask:
            guard let answers else { throw PersonaJobError.serviceUnavailable(.ask) }
            let caseID = try requireCase(context)
            guard let question = context.question, let access = context.access else {
                throw PersonaJobError.missingContext("ask requires a question and an access context")
            }
            _ = try await answers.answer(caseID: caseID, question: question, access: access)
            return PersonaJobLaunch(job: job, summary: "Answered over the case's authorized scope", producedID: caseID)

        case .dataLab:
            guard let dataLab else { throw PersonaJobError.serviceUnavailable(.dataLab) }
            let caseID = try requireCase(context)
            guard let access = context.access else { throw PersonaJobError.missingContext("dataLab requires an access context") }
            let (included, withheld) = try await dataLab.eligibleSourceVersions(caseID: caseID, access: access)
            return PersonaJobLaunch(job: job, summary: "Eligible sources: \(included.count) included, \(withheld) withheld by sensitivity", producedID: caseID)

        case .subjectDossier:
            guard let subjectDossier else { throw PersonaJobError.serviceUnavailable(.subjectDossier) }
            let caseID = try requireCase(context)
            let subjects = try await subjectDossier.subjects(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(subjects.count) subject(s) in scope", producedID: caseID)

        case .identityResolution:
            guard let identityResolution else { throw PersonaJobError.serviceUnavailable(.identityResolution) }
            let caseID = try requireCase(context)
            let log = try await identityResolution.decisionLog(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(log.count) identity decision(s) recorded", producedID: caseID)

        case .analysis:
            guard let analysis else { throw PersonaJobError.serviceUnavailable(.analysis) }
            let caseID = try requireCase(context)
            let hypotheses = try await analysis.hypotheses(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(hypotheses.count) lead/hypothesis item(s)", producedID: caseID)

        case .sourceReliability:
            guard let reliability else { throw PersonaJobError.serviceUnavailable(.sourceReliability) }
            let caseID = try requireCase(context)
            let schedule = try await reliability.schedule(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(schedule.count) source(s) on the reliability schedule", producedID: caseID)

        case .contradictionGap:
            guard let contradictionGap else { throw PersonaJobError.serviceUnavailable(.contradictionGap) }
            let caseID = try requireCase(context)
            let contradictions = try await contradictionGap.contradictions(caseID: caseID)
            let gaps = try await contradictionGap.gaps(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(contradictions.count) contradiction(s), \(gaps.count) gap(s) in scope", producedID: caseID)

        case .evidenceCustody:
            guard let custody else { throw PersonaJobError.serviceUnavailable(.evidenceCustody) }
            let caseID = try requireCase(context)
            let manifest = try await custody.manifest(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(manifest.count) custody manifest entr(y/ies)", producedID: caseID)

        case .findings:
            guard let findings else { throw PersonaJobError.serviceUnavailable(.findings) }
            let caseID = try requireCase(context)
            guard let access = context.access else { throw PersonaJobError.missingContext("findings requires an access context") }
            let f = try await findings.buildFindings(caseID: caseID, access: access, actor: context.actor, at: context.at)
            return PersonaJobLaunch(job: job, summary: "Built findings over \(f.authorizedSourceVersionIDs.count) authorized source version(s)", producedID: f.run.id)

        case .closure:
            guard let closure else { throw PersonaJobError.serviceUnavailable(.closure) }
            let caseID = try requireCase(context)
            let latest = try await closure.latestClosure(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: latest.map { "Latest closure decision: \($0.decision.rawValue)" } ?? "No closure decision yet", producedID: caseID)

        // Method-engine-backed jobs: real services exist but the shared professional-method engine is not
        // booted in this build, so there is no live implementation to route into. Fail closed, honestly.
        case .methods:             throw PersonaJobError.serviceUnavailable(.methods)
        case .causalAnalysis:      throw PersonaJobError.serviceUnavailable(.causalAnalysis)
        case .linkage:             throw PersonaJobError.serviceUnavailable(.linkage)
        case .capaRegister:        throw PersonaJobError.serviceUnavailable(.capaRegister)
        case .effectivenessReview: throw PersonaJobError.serviceUnavailable(.effectivenessReview)
        }
    }

    // MARK: - Internals

    private func requireCase(_ context: PersonaJobLaunchContext) throws -> UUID {
        guard let caseID = context.caseID else { throw PersonaJobError.missingContext("this job requires a caseID") }
        return caseID
    }
}
