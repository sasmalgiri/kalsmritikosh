//
//  PM003Fixtures.swift
//  KalsmritikoshTests
//
//  PM-003 — shared helpers: a synthetic professional-method definition + registry,
//  a schema-2 `.method` workflow package, and an engine rig that binds the v1
//  method executor to schema 1 and the v2 registered-method executor to schema 2
//  (resolver = ProfessionalMethodWorkflowBridge). No concrete method algorithm.
//

import Foundation
@testable import Kalsmritikosh

struct PM003Rig {
    let db: Database
    let url: URL
    let workflowRepo: WorkflowRunRepository
    let methodRepo: MethodRunRepository
    let scopes: SensitiveScopeRepository
    let gate: CanonicalWorkflowEvidenceReferenceGate
    let bridge: ProfessionalMethodWorkflowBridge
    let engine: WorkflowStepExecutionEngine
}

enum PM003Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_900_000)
    static let methodDefID = "com.kalsmritikosh.method.synthetic"

    // MARK: - Definitions + registry

    static func syntheticDefinition(
        id: String = methodDefID, version: Int = 1, label: String = "Synthetic method"
    ) -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: id), version: version, label: label,
            category: .analysis,
            requiredInputRoles: [MethodInputRole(rawValue: "problemStatement")],
            allowedNodeKinds: [MethodNodeKind(rawValue: "cause")],
            allowedEdgeKinds: [MethodEdgeKind(rawValue: "contributesTo")],
            requiredReviews: [MethodRequiredReview(reviewKey: "final", label: "Final review")],
            validationIdentifiers: ["v.structure"],
            outputContract: MethodOutputContract(
                allowedFindingKinds: [MethodFindingKind(rawValue: "candidateCause")]))
    }

    static func registry(_ definitions: [ProfessionalMethodDefinition]) throws -> ProfessionalMethodRegistry {
        var builder = ProfessionalMethodRegistryBuilder()
        for definition in definitions { try builder.register(definition) }
        return builder.freeze()
    }

    // MARK: - Engine rig (v1 @ schema 1, v2 @ schema 2)

    static func makeRig(
        at url: URL, definitions: [ProfessionalMethodDefinition]? = nil
    ) async throws -> PM003Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79, at: url)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let workflowRepo = WorkflowRunRepository(database: db)
        let methodRepo = MethodRunRepository(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: scopes, scope: nil)
        let validator = WorkflowProvenanceReferenceValidator(gate: gate, database: db)
        let methodRegistry = try registry(definitions ?? [syntheticDefinition()])
        let bridge = ProfessionalMethodWorkflowBridge(
            registry: methodRegistry, repository: methodRepo, evidenceGate: gate)

        let builder = WorkflowStepExecutorRegistryBuilder()
        let v1: [any WorkflowStepExecutor] = [
            IntakeStepExecutor(), SelectEvidenceStepExecutor(gate: gate), ReviewEvidenceStepExecutor(),
            TimelineStepExecutor(gate: gate), GraphStepExecutor(gate: gate), CalculationStepExecutor(gate: gate),
            MethodStepExecutor(gate: gate), DecisionStepExecutor(), HumanApprovalStepExecutor(), ClosureStepExecutor()
        ]
        for executor in v1 {
            try builder.register(executor)
            try builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: executor.handledKind,
                executorID: executor.executorID, executorVersion: executor.executorVersion))
            if executor.handledKind != .method {
                try builder.bind(WorkflowStepExecutorBinding(
                    workflowSchemaVersion: 2, stepKind: executor.handledKind,
                    executorID: executor.executorID, executorVersion: executor.executorVersion))
            }
        }
        let v2 = RegisteredMethodStepExecutor(resolver: bridge)
        try builder.register(v2)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 2, stepKind: .method,
            executorID: v2.executorID, executorVersion: v2.executorVersion))
        let registry = builder.build()

        let requirements = WorkflowRequirementsEngine(
            repository: workflowRepo, requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
        let lifecycle = WorkflowLifecycleEngine(repository: workflowRepo, requirementsEngine: requirements)
        let engine = WorkflowStepExecutionEngine(
            registry: registry, lifecycleEngine: lifecycle, repository: workflowRepo,
            provenanceValidator: validator)
        return PM003Rig(db: db, url: url, workflowRepo: workflowRepo, methodRepo: methodRepo,
                        scopes: scopes, gate: gate, bridge: bridge, engine: engine)
    }

    // MARK: - Schema-2 method workflow package

    static func methodV2Package(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let methodID = StepDefinitionID(rawValue: "step.method.\(suffix)")
        let closureID = StepDefinitionID(rawValue: "step.closure.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let steps = [
            PersonaWorkflowStepDefinition(
                id: methodID, kind: .method, label: "Method", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: closureID)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.method-result", kind: .methodResultPresent,
                    label: "Method result attached", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: closureID, kind: .closure, label: "Closure",
                transitions: [WorkflowTransitionDefinition(label: "finish", targetStepID: doneID)]),
            PersonaWorkflowStepDefinition(id: doneID, kind: .closure, label: "Done", isTerminal: true)
        ]
        let appID = ApplicationDefinitionID(rawValue: "com.pm003.app.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pm003.wf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 2, label: "PM-003 WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pm003.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        return (ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "PM-003 App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: []), wfID)
    }

    /// Start a schema-2 method run and reach its (entry) method step.
    static func startMethodRun(
        _ rig: PM003Rig, package: (ResolvedPersonaApplicationPackage, WorkflowDefinitionID),
        workspaceID: UUID, at: Date
    ) async throws -> (runID: UUID, stepRunID: UUID) {
        let created = try await rig.workflowRepo.createRun(
            package: package.0, selectedWorkflowID: package.1, workspaceID: workspaceID,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: at)
        let started = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: at)
        return (created.run.id, started.run.currentStepRunID!)
    }

    /// Insert a MethodRun with the exact workflow back-references (soft refs — no
    /// workflow_runs row needed), add one gate-valid entity evidence link, and mark
    /// it completed. Returns the MethodRun id. Status is set directly because the
    /// lifecycle transition service is PM-004.
    @discardableResult
    static func makeCompletedMethodRun(
        _ rig: PM003Rig, workspaceID: UUID, definitionID: String = methodDefID, definitionVersion: Int = 1,
        workflowRunID: UUID, workflowStepRunID: UUID, entityID: UUID, at: Date, markCompleted: Bool = true
    ) async throws -> UUID {
        let runID = UUID()
        try await rig.db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version,
                                     workflow_run_id, workflow_step_run_id, status, revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(runID), .uuid(workspaceID), .text(definitionID), .integer(Int64(definitionVersion)),
                  .uuid(workflowRunID), .uuid(workflowStepRunID), .text("draft"), .integer(1),
                  .text("analyst"), .date(at), .date(at)])
        let link = MethodEvidenceLink(methodRunID: runID, targetKind: .entity, targetID: entityID,
            role: .supporting, ordinal: 0, addedBy: "analyst", addedAt: at)
        _ = try await rig.methodRepo.addEvidenceLink(link, expectedRevision: 1, gate: rig.gate, now: at)
        if markCompleted {
            try await rig.db.exec("UPDATE method_runs SET status='completed', completed_at=? WHERE id=?;",
                                  [.date(at), .uuid(runID)])
        }
        return runID
    }

    static func exec(
        _ rig: PM003Rig, runID: UUID, _ command: some Encodable,
        actor: WorkflowLifecycleActor, at: Date
    ) async throws -> ReopenedWorkflowRun {
        try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(command), actor: actor, now: at)
    }

    static func human(_ id: String, role: String? = nil) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: role)
    }
    static let system = WorkflowLifecycleActor(kind: .system, identifier: nil, role: nil)
}
