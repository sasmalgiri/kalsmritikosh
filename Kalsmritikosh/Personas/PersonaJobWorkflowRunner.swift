//
//  PersonaJobWorkflowRunner.swift
//  Kalsmritikosh
//
//  Unified path AUTO-13 (owner 2026-11-22) — not tested yet. Jobs run through the workflow engine: each
//  launch becomes a recorded workflow run (WorkflowStepExecutionEngine over the PJE-004 lifecycle), whose one
//  step's executor IS the old job path (PersonaJobService's direct launch). After the job ran, the source
//  versions its rows rest on are bound to the run (WorkflowAttachmentCoordinator — validated against the
//  canonical store and the sensitivity scope), the run is completed, and every attachment is checked
//  (WorkflowProvenanceInspector). The person sees the job's own result plus one line about the run.
//
//  The per-job workflow package: one `.method` step (entry and terminal) carrying one attachment artifact
//  definition; the registry binds `.method` (schema 1) to `PersonaJobStepExecutor` for this launch only.
//  When the workflow side fails BEFORE the job ran, the job is run directly and the failure is logged; after
//  the job ran, its result is returned whatever the bookkeeping did (logged) — the job is never run twice.
//

import Foundation
import os

/// The job result, handed from the executor (inside the engine) back to the runner.
actor PersonaJobLaunchBox {
    private(set) var value: PersonaJobLaunch?
    func set(_ v: PersonaJobLaunch) { value = v }
}

/// The step executor whose work is the old job path. No database access (the engine persists the state).
nonisolated struct PersonaJobStepExecutor: WorkflowStepExecutor {
    struct State: Codable, Sendable { var ran: Bool; var summary: String?; var sourceVersions: Int }
    struct Command: Codable, Sendable { var type: String }

    let executorID = WorkflowStepExecutorID(rawValue: "com.kalsmritikosh.executor.personaJob")
    let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    let handledKind: WorkflowStepKind = .method
    let job: @Sendable () async throws -> PersonaJobLaunch
    let box: PersonaJobLaunchBox

    func prepare(context: WorkflowStepPreparationContext) async throws -> WorkflowStepPreparationResult {
        let env = try makeEnvelope(state: State(ran: false, summary: nil, sourceVersions: 0), stepKind: handledKind)
        return WorkflowStepPreparationResult(inputJSON: "{}", stateJSON: env.json, stateSHA256: env.sha256,
                                             executorID: executorID, executorVersion: executorVersion)
    }

    func execute(context: WorkflowStepExecutionContext, commandJSON: String) async throws -> WorkflowStepExecutionResult {
        let command = try WorkflowStepPayloadCodec.decode(Command.self, from: commandJSON)
        switch command.type {
        case "run":
            let launch = try await job()
            await box.set(launch)
            let state = State(ran: true, summary: String(launch.summary.prefix(500)),
                              sourceVersions: Set(launch.items.flatMap(\.sourceVersionIDs)).count)
            let env = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: env.json, stateSHA256: env.sha256, disposition: .remainActive,
                                               detail: "job ran")
        case "complete":
            let state = try decodeCurrentState(State.self, from: context.stepRun)
            guard state.ran else { throw WorkflowStepExecutionError.malformedCommandJSON }
            let env = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: env.json, stateSHA256: env.sha256,
                                               outputJSON: try WorkflowStepPayloadCodec.encode(state),
                                               disposition: .completeTerminal, detail: "job recorded")
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }
}

public actor PersonaJobWorkflowRunner {
    private let database: Database
    private let runs: WorkflowRunRepository
    private let workspaces: WorkspaceRepository
    private let scopes: SensitiveScopeRepository

    static let artifactID = "artifact.job.sources"
    static let maxAttachments = 25

    public init(database: Database) {
        self.database = database
        self.runs = WorkflowRunRepository(database: database)
        self.workspaces = WorkspaceRepository(database: database)
        self.scopes = SensitiveScopeRepository(database: database)
    }

    /// The per-job workflow package (one recorded step: the job, with its source attachments).
    static func package(for job: PersonaJob) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let key = job.id.replacingOccurrences(of: " ", with: "-")
        let stepID = StepDefinitionID(rawValue: "step.job.\(key)")
        let step = PersonaWorkflowStepDefinition(
            id: stepID, kind: .method, label: job.title, isEntry: true, isTerminal: true,
            artifacts: [PersonaWorkflowArtifactDefinition(id: artifactID, label: "Sources the job's rows rest on",
                                                          workProductTemplateID: nil, isRequired: false)])
        let appID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.jobs.\(job.persona)")
        let wfID = WorkflowDefinitionID(rawValue: "com.kalsmritikosh.job.\(key)")
        let validated = try WorkflowDefinitionCompiler().compile(PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: job.title, steps: [step]))
        let termID = TerminologyDefinitionID(rawValue: "com.kalsmritikosh.jobs.term.\(job.persona)")
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: job.persona),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1),
            terminology: PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:]),
            objectSchemaKeys: [], objectSchemas: [], workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [], automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    /// Run `job` through the workflow engine; `direct` is the old job path (the step's work).
    public func run(job: PersonaJob, context: PersonaJobLaunchContext, workspaceID: UUID,
                    direct: @escaping @Sendable () async throws -> PersonaJobLaunch) async throws -> PersonaJobLaunch {
        let box = PersonaJobLaunchBox()
        let actor = WorkflowLifecycleActor(kind: .human, identifier: context.actor, role: nil)
        let gate = CanonicalWorkflowEvidenceReferenceGate(database: database, scopeRepository: scopes, scope: nil)
        let engine: WorkflowStepExecutionEngine
        let runID: UUID
        do {
            let executor = PersonaJobStepExecutor(job: direct, box: box)
            let builder = WorkflowStepExecutorRegistryBuilder()
            try builder.register(executor)
            try builder.bind(WorkflowStepExecutorBinding(workflowSchemaVersion: 1, stepKind: executor.handledKind,
                                                         executorID: executor.executorID, executorVersion: executor.executorVersion))
            let requirements = WorkflowRequirementsEngine(repository: runs, workspaces: workspaces,
                                                          requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
            engine = WorkflowStepExecutionEngine(
                registry: builder.build(),
                lifecycleEngine: WorkflowLifecycleEngine(repository: runs, requirementsEngine: requirements),
                repository: runs,
                provenanceValidator: WorkflowProvenanceReferenceValidator(gate: gate, database: database))
            let (pkg, wfID) = try Self.package(for: job)
            let created = try await runs.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: workspaceID, title: job.title,
                                                   parentRunID: nil, actorKind: .human, actorIdentifier: context.actor, now: Date())
            runID = created.run.id
            _ = try await engine.startRun(runID: runID, actor: actor, now: Date())
        } catch {
            KalsmritikoshLog.app.error("Job workflow: the run could not be started (\(String(describing: error), privacy: .public)); the job runs directly")
            return try await direct()
        }

        do {
            _ = try await engine.executeCommand(runID: runID, commandJSON: #"{"type":"run"}"#, actor: actor, now: Date())
        } catch {
            guard let launch = await box.value else { throw error }   // the job itself failed: its error stands
            KalsmritikoshLog.app.error("Job workflow: the job ran but its step state was not saved: \(String(describing: error), privacy: .public)")
            return launch
        }
        guard let launch = await box.value else { return try await direct() }

        // Attach the source versions the job's rows rest on (validated; a refused one is logged, not fatal).
        let coordinator = WorkflowAttachmentCoordinator(workflowRuns: runs, database: database,
                                                        sourceRelations: SourceRelationsRepository(database: database),
                                                        gate: gate, scopes: scopes)
        var attached = 0, refused = 0
        let versions = Array(Set(launch.items.flatMap(\.sourceVersionIDs))).sorted { $0.uuidString < $1.uuidString }
        for sv in versions.prefix(Self.maxAttachments) {
            do {
                _ = try await coordinator.attachCanonicalSource(
                    runID: runID,
                    request: WorkflowCanonicalAttachmentRequest(artifactDefinitionID: Self.artifactID, sourceVersionID: sv,
                                                                displayName: "Source of \(job.title)"),
                    actor: actor, at: Date())
                attached += 1
            } catch {
                refused += 1
                KalsmritikoshLog.app.info("Job workflow: a source was not attached: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            _ = try await engine.executeCommand(runID: runID, commandJSON: #"{"type":"complete"}"#, actor: actor, now: Date())
        } catch {
            KalsmritikoshLog.app.error("Job workflow: the run was not completed: \(String(describing: error), privacy: .public)")
        }

        // Check every attachment against the canonical store under the job's access.
        var available = 0
        if let access = context.access, attached > 0 {
            let inspector = WorkflowProvenanceInspector(repository: runs, database: database, scopes: scopes)
            do {
                for artifact in try await runs.fetchRun(runID).artifacts {
                    do {
                        if try await inspector.inspectAttachment(artifactID: artifact.id, access: access).sourceAvailability == .available { available += 1 }
                    } catch {
                        KalsmritikoshLog.app.info("Job workflow: an artifact is not an attachment or could not be inspected: \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                KalsmritikoshLog.app.error("Job workflow: the run could not be reopened for inspection: \(String(describing: error), privacy: .public)")
            }
        }
        var line = " · Recorded as workflow run \(runID.uuidString.prefix(8))"
        if !versions.isEmpty {
            line += ": \(attached) source(s) attached" + (context.access != nil && attached > 0 ? ", \(available) available" : "")
                + (refused > 0 ? ", \(refused) not attached" : "")
                + (versions.count > Self.maxAttachments ? ", \(versions.count - Self.maxAttachments) beyond the limit" : "")
        }
        return PersonaJobLaunch(job: launch.job, summary: launch.summary + line, producedID: launch.producedID, items: launch.items)
    }
}
