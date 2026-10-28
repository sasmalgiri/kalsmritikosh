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
    // #143 — the case-scoped method-engine services (shared ProfessionalMethod engine).
    private let methods: InvestigationMethodService?
    private let causal: InvestigationCausalService?
    private let linkage: InvestigationLinkageService?
    private let capa: InvestigationCAPAService?
    private let workspaceIntake: InvestigationWorkspaceIntake?
    /// §3 — shared executors: the case's evidence read under the job's access context, and the store
    /// their typed results are persisted to.
    public typealias CaseFactsLoader = @Sendable (UUID, SensitiveAccessContext) async throws -> JobEvidence?
    private let caseFacts: CaseFactsLoader?
    private let jobResults: JobResultRepository?

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
                dataLab: InvestigationDataLabService?,
                methods: InvestigationMethodService? = nil,
                causal: InvestigationCausalService? = nil,
                linkage: InvestigationLinkageService? = nil,
                capa: InvestigationCAPAService? = nil,
                workspaceIntake: InvestigationWorkspaceIntake? = nil,
                caseFacts: CaseFactsLoader? = nil,
                jobResults: JobResultRepository? = nil) {
        self.catalog = catalog
        self.cases = cases; self.answers = answers; self.subjectDossier = subjectDossier
        self.identityResolution = identityResolution; self.analysis = analysis; self.reliability = reliability
        self.contradictionGap = contradictionGap; self.custody = custody; self.closure = closure
        self.findings = findings; self.dataLab = dataLab
        self.methods = methods; self.causal = causal; self.linkage = linkage; self.capa = capa
        self.workspaceIntake = workspaceIntake
        self.caseFacts = caseFacts
        self.jobResults = jobResults
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
        // §3 — a job with a shared executor produces its own typed, persisted result.
        if let executor = JobExecutorKind.assignments[job.id], let caseFacts, let jobResults {
            return try await runExecutor(executor, job: job, context: context, caseFacts: caseFacts, results: jobResults)
        }
        switch job.kind {

        case .caseIntake:
            guard let cases else { throw PersonaJobError.serviceUnavailable(.caseIntake) }
            if let ws = context.workspaceID, let title = context.title {
                var c = try await cases.createCase(workspaceID: ws, title: title, actor: context.actor, at: context.at)
                // The workspace's documents (and their attachments) come into the case's scope, each
                // inclusion recorded — without this the new case had nothing to answer from.
                var included = 0
                if let workspaceIntake {
                    (c, included) = try await workspaceIntake.includeWorkspaceSources(caseID: c.id, actor: context.actor, at: context.at)
                }
                return PersonaJobLaunch(job: job, summary: "Created case \"\(title)\" (rev \(c.revision)) with \(included) source(s) in scope", producedID: c.id)
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
            let answer = try await answers.answer(caseID: caseID, question: question, access: access)
            return try await askLaunch(job, answer: answer.verified, question: question, caseID: caseID, context: context)

        case .dataLab:
            guard let dataLab else { throw PersonaJobError.serviceUnavailable(.dataLab) }
            let caseID = try requireCase(context)
            guard let access = context.access else { throw PersonaJobError.missingContext("dataLab requires an access context") }
            let (included, withheld) = try await dataLab.eligibleSourceVersions(caseID: caseID, access: access)
            let items = included.map { PersonaWorkItem(id: $0.uuidString, title: "Eligible source", sourceVersionIDs: [$0]) }
            return PersonaJobLaunch(job: job, summary: "Eligible sources: \(included.count) included, \(withheld) withheld by sensitivity", producedID: caseID, items: items)

        case .subjectDossier:
            guard let subjectDossier else { throw PersonaJobError.serviceUnavailable(.subjectDossier) }
            let caseID = try requireCase(context)
            let subjects = try await subjectDossier.subjects(caseID: caseID)
            let items = subjects.map { PersonaWorkItem(id: $0.id.uuidString, title: $0.label, detail: "Identity \($0.identityStatus.rawValue)") }
            return PersonaJobLaunch(job: job, summary: "\(subjects.count) subject(s) in scope", producedID: caseID, items: items)

        case .identityResolution:
            guard let identityResolution else { throw PersonaJobError.serviceUnavailable(.identityResolution) }
            let caseID = try requireCase(context)
            let log = try await identityResolution.decisionLog(caseID: caseID)
            let items = log.map { PersonaWorkItem(id: $0.id.uuidString, title: "Identity decision #\($0.sequence): \($0.kind.rawValue)",
                                                  detail: $0.rationale ?? "by \($0.actor)") }
            return PersonaJobLaunch(job: job, summary: "\(log.count) identity decision(s) recorded", producedID: caseID, items: items)

        case .analysis:
            guard let analysis else { throw PersonaJobError.serviceUnavailable(.analysis) }
            let caseID = try requireCase(context)
            let hypotheses = try await analysis.hypotheses(caseID: caseID)
            let items = hypotheses.map { PersonaWorkItem(id: $0.id.uuidString, title: $0.statement,
                                                         detail: "\($0.kind.rawValue), \($0.status.rawValue)") }
            return PersonaJobLaunch(job: job, summary: "\(hypotheses.count) lead/hypothesis item(s)", producedID: caseID, items: items)

        case .sourceReliability:
            guard let reliability else { throw PersonaJobError.serviceUnavailable(.sourceReliability) }
            let caseID = try requireCase(context)
            let schedule = try await reliability.schedule(caseID: caseID)
            let items = schedule.map { e in
                PersonaWorkItem(id: e.sourceVersionID.uuidString,
                                title: e.assessment.map { "Reliability \($0.reliability.rawValue), independence \($0.independence.rawValue)" } ?? "Not yet assessed",
                                detail: e.isSingleSource ? "Single source — corroboration needed" : e.assessment?.rationale,
                                sourceVersionIDs: [e.sourceVersionID])
            }
            return PersonaJobLaunch(job: job, summary: "\(schedule.count) source(s) on the reliability schedule", producedID: caseID, items: items)

        case .contradictionGap:
            guard let contradictionGap else { throw PersonaJobError.serviceUnavailable(.contradictionGap) }
            let caseID = try requireCase(context)
            let contradictions = try await contradictionGap.contradictions(caseID: caseID)
            let gaps = try await contradictionGap.gaps(caseID: caseID)
            let items = contradictions.map { c in
                PersonaWorkItem(id: c.contradiction.id.uuidString, title: "Contradiction: \(c.contradiction.description)",
                                detail: "\u{201C}\(c.contradiction.claimA)\u{201D} vs \u{201C}\(c.contradiction.claimB)\u{201D}",
                                objectIDs: [c.contradiction.evidenceA, c.contradiction.evidenceB].compactMap { $0 })
            } + gaps.map { g in
                PersonaWorkItem(id: g.gap.id.uuidString, title: "Gap: \(g.gap.description)", detail: g.gap.reason,
                                objectIDs: [g.gap.evidenceObjectID].compactMap { $0 })
            }
            return PersonaJobLaunch(job: job, summary: "\(contradictions.count) contradiction(s), \(gaps.count) gap(s) in scope", producedID: caseID, items: items)

        case .evidenceCustody:
            guard let custody else { throw PersonaJobError.serviceUnavailable(.evidenceCustody) }
            let caseID = try requireCase(context)
            let manifest = try await custody.manifest(caseID: caseID)
            let items = manifest.map { m in
                PersonaWorkItem(id: m.sourceVersionID.uuidString,
                                title: m.contentHash.map { "SHA-256 \($0.prefix(16))…" } ?? "No content hash",
                                detail: m.custodyEvents.map(\.kind.rawValue).joined(separator: " → "),
                                sourceVersionIDs: [m.sourceVersionID])
            }
            return PersonaJobLaunch(job: job, summary: "\(manifest.count) custody manifest entr(y/ies)", producedID: caseID, items: items)

        case .findings:
            guard let findings else { throw PersonaJobError.serviceUnavailable(.findings) }
            let caseID = try requireCase(context)
            guard let access = context.access else { throw PersonaJobError.missingContext("findings requires an access context") }
            let f = try await findings.buildFindings(caseID: caseID, access: access, actor: context.actor, at: context.at)
            let items = f.authorizedSourceVersionIDs.map { PersonaWorkItem(id: $0.uuidString, title: "Source in the findings", sourceVersionIDs: [$0]) }
            return PersonaJobLaunch(job: job, summary: "Built findings over \(f.authorizedSourceVersionIDs.count) authorized source version(s)", producedID: f.run.id, items: items)

        case .closure:
            guard let closure else { throw PersonaJobError.serviceUnavailable(.closure) }
            let caseID = try requireCase(context)
            let latest = try await closure.latestClosure(caseID: caseID)
            let items = latest.map { d in
                [PersonaWorkItem(id: d.id.uuidString, title: "Closure #\(d.sequence): \(d.decision.rawValue)", detail: d.rationale)]
                    + d.unresolvedItems.enumerated().map { PersonaWorkItem(id: "\(d.id.uuidString)-open-\($0.offset)", title: "Unresolved: \($0.element)") }
            } ?? []
            return PersonaJobLaunch(job: job, summary: latest.map { "Latest closure decision: \($0.decision.rawValue)" } ?? "No closure decision yet", producedID: caseID, items: items)

        // Method-engine-backed jobs — route into the SHARED ProfessionalMethod engine (booted in production).
        // Each launch resolves the case-scoped recommended methods, proving the real engine is reachable; the
        // full run (evidence selection + validation + human review) is exercised by the persona acceptance.
        case .methods:
            guard let methods else { throw PersonaJobError.serviceUnavailable(.methods) }
            let caseID = try requireCase(context)
            let recs = try await methods.recommendedMethods(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(recs.count) professional method(s) available for this case", producedID: caseID, items: Self.methodItems(recs))

        case .causalAnalysis:
            guard let causal else { throw PersonaJobError.serviceUnavailable(.causalAnalysis) }
            let caseID = try requireCase(context)
            let recs = try await causal.recommendedCausalMethods(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(recs.count) causal method(s) available (Five Whys / Fishbone / Root-cause)", producedID: caseID, items: Self.methodItems(recs))

        case .linkage:
            guard let linkage else { throw PersonaJobError.serviceUnavailable(.linkage) }
            let caseID = try requireCase(context)
            let recs = try await linkage.recommendedLinkageMethods(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(recs.count) linkage method(s) available (Timeline / Relationship / Transaction)", producedID: caseID, items: Self.methodItems(recs))

        case .capaRegister:
            guard let capa else { throw PersonaJobError.serviceUnavailable(.capaRegister) }
            let caseID = try requireCase(context)
            let recs = try await capa.recommendedCAPAMethods(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "\(recs.count) CAPA / effectiveness method(s) available", producedID: caseID, items: Self.methodItems(recs))

        case .effectivenessReview:
            guard let capa else { throw PersonaJobError.serviceUnavailable(.effectivenessReview) }
            let caseID = try requireCase(context)
            let recs = try await capa.recommendedCAPAMethods(caseID: caseID)
            return PersonaJobLaunch(job: job, summary: "Effectiveness review available among \(recs.count) CAPA method(s)", producedID: caseID, items: Self.methodItems(recs))
        }
    }

    // MARK: - Internals

    /// Methods as rows: what each needs from the case and must be reviewed by, so the investigator
    /// can start one from the list.
    nonisolated static func methodItems(_ methods: [ProfessionalMethodDefinition]) -> [PersonaWorkItem] {
        methods.map { m in
            PersonaWorkItem(id: "\(m.id.rawValue)@\(m.version)", title: m.label,
                            detail: "Needs: " + m.requiredInputRoles.map { String(describing: $0) }.joined(separator: ", "))
        }
    }

    private func requireCase(_ context: PersonaJobLaunchContext) throws -> UUID {
        guard let caseID = context.caseID else { throw PersonaJobError.missingContext("this job requires a caseID") }
        return caseID
    }

    // MARK: - Shared executors (§3)

    private func runExecutor(_ executor: JobExecutorKind, job: PersonaJob, context: PersonaJobLaunchContext,
                             caseFacts: CaseFactsLoader, results: JobResultRepository) async throws -> PersonaJobLaunch {
        let caseID = try requireCase(context)
        guard let access = context.access else { throw PersonaJobError.missingContext("\(job.id) requires an access context") }
        let run: JobRun
        switch executor {
        case .actionReview:
            var register: JobResultRecord?
            if let registerJob = JobExecutorKind.reviewedRegister[job.id] { register = try await results.latest(caseID: caseID, jobID: registerJob) }
            run = ActionExecutor.review(register: register)
        case .methodReadiness:
            guard let methods else { throw PersonaJobError.serviceUnavailable(.methods) }
            run = Self.methodReadiness(try await methods.recommendedMethods(caseID: caseID))
        default:
            guard let evidence = try await caseFacts(caseID, access) else { throw PersonaJobError.missingContext("the case's evidence could not be read") }
            guard let r = JobExecutorKind.run(executor, evidence) else { throw PersonaJobError.missingContext("\(job.id) has no evidence executor") }
            run = r
        }
        return try await persist(run, job: job, caseID: caseID, context: context, results: results)
    }

    /// Save a run as the job's current result and hand it back as work items.
    private func persist(_ run: JobRun, job: PersonaJob, caseID: UUID, context: PersonaJobLaunchContext,
                         results: JobResultRepository) async throws -> PersonaJobLaunch {
        let family = JobContracts.contract(for: job.id)?.family ?? .chronologyLinkage
        let id = try await results.save(caseID: caseID, jobID: job.id, family: family, state: run.state, content: run.content,
                                        actor: context.actor, at: context.at)
        let items = run.content.rows.enumerated().map { i, row in
            PersonaWorkItem(id: "\(id.uuidString)#\(i)", title: [row.date, row.title].compactMap { $0 }.joined(separator: " — "),
                            detail: ([row.detail] + row.flags.map { "⚑ " + $0 }).compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                            sourceVersionIDs: row.refs.compactMap(\.sourceVersionID), objectIDs: row.refs.compactMap(\.objectID))
        }
        let summary = "\(run.state.rawValue): \(run.content.rows.count) row(s)" + (run.content.limitations.isEmpty ? "" : " — " + run.content.limitations.joined(separator: " "))
        return PersonaJobLaunch(job: job, summary: summary, producedID: id, items: items)
    }

    /// §3 — the ask job hands back what was answered (or why it was refused) with its citations, and
    /// keeps it as the job's result when the result store is wired.
    private func askLaunch(_ job: PersonaJob, answer v: VerifiedAnswer, question: String, caseID: UUID,
                           context: PersonaJobLaunchContext) async throws -> PersonaJobLaunch {
        let text = v.refused ? "Refused: " + (v.refusalReason ?? "the case's documents do not support an answer") : (v.answerText ?? v.body)
        var rows = [JobResultRow(title: text, detail: "Question: " + question,
                                 flags: v.refused ? ["refused"] : (v.contradictions.isEmpty ? [] : ["\(v.contradictions.count) conflict(s) shown"]))]
        rows += v.citations.map { c in JobResultRow(title: String(c.snippet.prefix(300)), flags: ["citation"], refs: [StudioEvidenceRef(objectID: c.objectID, quote: c.snippet)]) }
        let run: JobRun = (v.refused ? .blocked : .draft,
                           JobResultContent(rows: rows, limitations: v.refused ? ["No supporting passage in the case's authorised sources."] : [],
                                            nextActions: ["Read the answer against its citations; the judgement is yours."]))
        if let jobResults { return try await persist(run, job: job, caseID: caseID, context: context, results: jobResults) }
        return PersonaJobLaunch(job: job, summary: (v.refused ? "Refused" : "Answered") + " over the case's authorized scope: " + String(text.prefix(160)),
                                producedID: caseID, items: rows.enumerated().map { PersonaWorkItem(id: "\(caseID.uuidString)#\($0.offset)", title: $0.element.title,
                                                                                                    objectIDs: $0.element.refs.compactMap(\.objectID)) })
    }

    /// The case's applicable methods with what each needs and who must review it; running one is the
    /// person's choice (the run itself is saved by the method engine).
    nonisolated static func methodReadiness(_ methods: [ProfessionalMethodDefinition]) -> JobRun {
        guard !methods.isEmpty else {
            return JobText.blocked("No professional method applies to this case's evidence yet.", "Add evidence to the case, or choose a method from the catalog.")
        }
        let rows = methods.map { m in
            JobResultRow(title: "\(m.label) (v\(m.version))",
                         detail: "Needs: " + m.requiredInputRoles.map { String(describing: $0) }.joined(separator: ", "),
                         flags: ["not run"])
        }
        return (.draft, JobResultContent(rows: rows, limitations: ["A method's outcome exists only once it is run and reviewed; none is implied here."],
                                         nextActions: ["Choose a method, select its evidence and run it; an inconclusive run is saved as inconclusive."]))
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
