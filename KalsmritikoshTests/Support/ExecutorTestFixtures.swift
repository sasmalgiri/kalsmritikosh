//
//  ExecutorTestFixtures.swift
//  KalsmritikoshTests
//
//  PJE-006A — DB-free fixture helpers shared by all executor test suites.
//  Builds a minimal ValidatedWorkflowDefinition + WorkflowRunContractSnapshot
//  so executor tests can call prepare() and execute() directly without a DB.
//

import Foundation
@testable import Kalsmritikosh

// MARK: - Workflow rig

struct ExecutorTestRig {
    let validated: ValidatedWorkflowDefinition
    let entryStep: PersonaWorkflowStepDefinition
    let contract: WorkflowRunContractSnapshot
}

func makeExecutorTestRig(
    kind: WorkflowStepKind,
    reqs: [PersonaWorkflowRequirement] = [],
    suffix: String = ""
) throws -> ExecutorTestRig {
    let sfx = suffix.isEmpty ? kind.rawValue : "\(kind.rawValue).\(suffix)"
    let entryID = StepDefinitionID(rawValue: "step.entry.\(sfx)")
    let doneID  = StepDefinitionID(rawValue: "step.done.\(sfx)")

    let entry = PersonaWorkflowStepDefinition(
        id: entryID, kind: kind, label: "Entry", isEntry: true,
        transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
        requirements: reqs)
    let done = PersonaWorkflowStepDefinition(
        id: doneID, kind: .closure, label: "Done", isTerminal: true)

    let appID = ApplicationDefinitionID(rawValue: "com.pje006a.exec.test.\(sfx)")
    let wfID  = WorkflowDefinitionID(rawValue: "com.pje006a.exec.wf.\(sfx)")
    let wfDef = PersonaWorkflowDefinition(
        id: wfID, version: 1, schemaVersion: 1, label: "Exec Test WF", steps: [entry, done])
    let validated = try WorkflowDefinitionCompiler().compile(wfDef)

    let app    = PersonaApplicationDefinition(id: appID, version: 1, label: "Exec Test App")
    let termID = TerminologyDefinitionID(rawValue: "com.pje006a.exec.term.\(sfx)")
    let term   = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
    let pkg    = ResolvedPersonaApplicationPackage(
        applicationKey: RegistryKey(id: appID, version: 1),
        application: app, toolKeys: [], tools: [],
        workflowKeys: [RegistryKey(id: wfID, version: 1)],
        workflows: [validated],
        terminologyKey: RegistryKey(id: termID, version: 1),
        terminology: term,
        objectSchemaKeys: [], objectSchemas: [],
        workProductKeys: [], workProducts: [],
        validatorKeys: [], validators: [],
        automationKeys: [], automations: [])
    let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)

    // reconstructDefinition() must succeed because we just built it
    guard let reconstructed = contract.reconstructDefinition() else {
        throw ExecutorTestFixtureError.reconstructionFailed
    }
    let reconEntry = reconstructed.definition.steps.first(where: { $0.isEntry })
    guard let resolvedEntry = reconEntry else {
        throw ExecutorTestFixtureError.noEntryStep
    }
    return ExecutorTestRig(validated: reconstructed, entryStep: resolvedEntry, contract: contract)
}

// MARK: - Context builders

func makePreparationCtx(
    rig: ExecutorTestRig,
    runID: UUID = UUID()
) -> WorkflowStepPreparationContext {
    let t0 = Date(timeIntervalSince1970: 1_753_000_000)
    return WorkflowStepPreparationContext(
        runID: runID, workspaceID: UUID(),
        runRevision: 1, workflow: rig.validated, step: rig.entryStep,
        actor: .system, preparedAt: t0)
}

func makeExecutionCtx(
    executor: any WorkflowStepExecutor,
    rig: ExecutorTestRig,
    stateJSON: String,
    priorStepStates: [(kind: WorkflowStepKind, stateJSON: String)] = [],
    workspaceID: UUID = UUID()
) throws -> WorkflowStepExecutionContext {
    let t0       = Date(timeIntervalSince1970: 1_753_000_000)
    let runID    = UUID()
    let stepRunID = UUID()
    let step     = rig.entryStep

    let run = WorkflowRun(
        id: runID, workspaceID: workspaceID,
        applicationDefinitionID: ApplicationDefinitionID(rawValue: "com.pje006a.exec.test"),
        applicationDefinitionVersion: 1,
        workflowDefinitionID: WorkflowDefinitionID(rawValue: "com.pje006a.exec.wf"),
        workflowDefinitionVersion: 1,
        title: nil, status: .active,
        currentStepDefinitionID: step.id,
        currentStepRunID: stepRunID,
        contractSnapshotJSON: "{}", contractSnapshotSHA256: "",
        snapshotSchemaVersion: 1, revision: 1,
        parentRunID: nil, supersededByRunID: nil,
        createdAt: t0, updatedAt: t0, startedAt: t0,
        pausedAt: nil, completedAt: nil, cancelledAt: nil, cancellationReason: nil)

    let stepRun = WorkflowStepRun(
        id: stepRunID, workflowRunID: runID,
        stepDefinitionID: step.id, stepKind: step.kind,
        attempt: 1, sequence: 1, status: .active,
        executorID: executor.executorID.rawValue,
        executorVersion: executor.executorVersion.rawValue,
        inputJSON: "{}", stateJSON: stateJSON,
        outputJSON: nil, stateSHA256: "",
        enteredAt: t0, updatedAt: t0, completedAt: nil)

    // Prior (completed) step runs, e.g. a selectEvidence selection that a
    // reviewEvidence executor reads from the aggregate.
    let prior = priorStepStates.enumerated().map { index, entry in
        WorkflowStepRun(
            id: UUID(), workflowRunID: runID,
            stepDefinitionID: StepDefinitionID(rawValue: "step.prior.\(index)"),
            stepKind: entry.kind,
            attempt: 1, sequence: index + 1, status: .completed,
            executorID: "com.kalsmritikosh.step.\(entry.kind.rawValue)",
            executorVersion: "1.0",
            inputJSON: "{}", stateJSON: entry.stateJSON,
            outputJSON: nil, stateSHA256: "",
            enteredAt: t0, updatedAt: t0, completedAt: t0)
    }

    let aggregate = ReopenedWorkflowRun(
        run: run, contract: rig.contract,
        stepRuns: prior + [stepRun], decisions: [],
        artifacts: [], checkpoints: [], attentionItems: [], events: [])

    return try WorkflowStepExecutionContext(
        aggregate: aggregate, workflow: rig.validated,
        step: step, stepRun: stepRun, actor: .system, executedAt: t0,
        executorID: executor.executorID, executorVersion: executor.executorVersion)
}

// MARK: - Decode state from envelope JSON

func decodeEnvelopeState<S: Codable & Sendable>(_ type: S.Type, from json: String) throws -> S {
    try WorkflowStepPayloadCodec.decode(WorkflowStepStateEnvelope<S>.self, from: json).state
}

// MARK: - Fixture evidence gate (PJE-006B)

/// DB-free gate for executor unit tests. Permits everything except explicitly
/// denied object IDs (or everything, when `denyAll` is set).
struct FixtureEvidenceGate: WorkflowEvidenceReferenceGating {
    var deniedIDs: Set<UUID> = []
    var denyAll = false

    func verdict(
        kind: WorkflowEvidenceObjectKind,
        canonicalObjectID: UUID,
        workspaceID: UUID
    ) async -> WorkflowEvidenceGateVerdict {
        if denyAll || deniedIDs.contains(canonicalObjectID) {
            return .denied(reason: "Fixture gate denial for \(kind.rawValue)")
        }
        return .permitted
    }
}

// MARK: - Error

enum ExecutorTestFixtureError: Error {
    case reconstructionFailed
    case noEntryStep
}
