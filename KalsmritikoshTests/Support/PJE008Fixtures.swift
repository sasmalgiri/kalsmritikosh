//
//  PJE008Fixtures.swift
//  KalsmritikoshTests
//
//  PJE-008 — Method Boundary Acceptance shared helpers. Method-step packages and
//  a generic externally-produced method-result builder, layered on the PJE-007
//  provenance rig. Everything here is GENERIC: opaque adapter identifiers, no
//  Stage 4 professional-method algorithm, no method-specific persistence.
//

import Foundation
@testable import Kalsmritikosh

enum PJE008Fixtures {

    static let t0 = PJE007Fixtures.t0

    // MARK: - Generic method result (adapter reference envelope only)

    static func methodResult(
        providerID: String = "com.external.provider",
        providerVersion: String = "1.0",
        methodID: String = "method.external.generic-analysis",
        runRef: String = "ext-run-1",
        resultRef: String = "ext-result-1",
        summary: String = "Externally produced generic method result",
        provenance: [WorkflowMethodProvenanceReference],
        completedBy: String = "analyst-1",
        at: Date,
        limitations: [String] = ["single-source"]
    ) -> WorkflowMethodResultReference {
        WorkflowMethodResultReference(
            providerID: providerID, providerVersion: providerVersion,
            methodDefinitionID: methodID, methodRunReferenceID: runRef,
            resultReferenceID: resultRef, summary: summary,
            provenanceReferences: provenance, completedBy: completedBy,
            completedAt: at, limitations: limitations)
    }

    static func entityRef(_ id: UUID) -> WorkflowMethodProvenanceReference {
        WorkflowMethodProvenanceReference(objectKind: "entity", canonicalObjectID: id.uuidString)
    }
    static func gapRef(_ id: UUID) -> WorkflowMethodProvenanceReference {
        WorkflowMethodProvenanceReference(objectKind: "gap", canonicalObjectID: id.uuidString)
    }

    // MARK: - Packages

    /// method (entry, optional blocking methodResultPresent) → closure.
    static func methodPackage(
        suffix: String, blockingResultRequirement: Bool = true
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let methodID = StepDefinitionID(rawValue: "step.method.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let requirements: [PersonaWorkflowRequirement] = blockingResultRequirement
            ? [PersonaWorkflowRequirement(
                id: "req.method-result", kind: .methodResultPresent,
                label: "Method result attached", isBlocking: true)]
            : []
        let method = PersonaWorkflowStepDefinition(
            id: methodID, kind: .method, label: "Method", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            requirements: requirements)
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(suffix: suffix, steps: [method, done])
    }

    /// method (entry) → humanApproval (approverRoles) → closure. Reject routes to a
    /// separate terminal so both branches are declared.
    static func methodApprovalPackage(
        suffix: String, approverRoles: [String] = ["reviewer"]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            method: StepDefinitionID(rawValue: "step.method.\(suffix)"),
            approval: StepDefinitionID(rawValue: "step.approval.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)"),
            rejected: StepDefinitionID(rawValue: "step.rejected.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.method, kind: .method, label: "Method", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.approval)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.method-result", kind: .methodResultPresent,
                    label: "Method result attached", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.approval, kind: .humanApproval, label: "Approve",
                transitions: [
                    WorkflowTransitionDefinition(label: "approved", targetStepID: ids.done),
                    WorkflowTransitionDefinition(label: "rejected", targetStepID: ids.rejected)
                ],
                approverRoles: approverRoles),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true),
            PersonaWorkflowStepDefinition(
                id: ids.rejected, kind: .closure, label: "Rejected", isTerminal: true)
        ]
        return try makePackage(suffix: suffix, steps: steps)
    }

    /// method (entry) → decision (humanRequired branches) → closure.
    static func methodDecisionPackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            method: StepDefinitionID(rawValue: "step.method.\(suffix)"),
            decision: StepDefinitionID(rawValue: "step.decision.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.method, kind: .method, label: "Method", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.decision)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.method-result", kind: .methodResultPresent,
                    label: "Method result attached", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.decision, kind: .decision, label: "Decide",
                transitions: [
                    WorkflowTransitionDefinition(label: "proceed", targetStepID: ids.done),
                    WorkflowTransitionDefinition(label: "halt", targetStepID: ids.done)
                ],
                decisionBranches: ["proceed", "halt"]),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true)
        ]
        return try makePackage(suffix: suffix, steps: steps)
    }

    static func makePackage(
        suffix: String, steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje008.app.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje008.wf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-008 WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje008.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        return (ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "PJE-008 App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: []), wfID)
    }

    // MARK: - Drivers

    /// Start a run and reach its (entry) method step. Returns the run ID.
    @discardableResult
    static func startMethodRun(
        _ rig: PJE007Rig, package: (ResolvedPersonaApplicationPackage, WorkflowDefinitionID),
        workspaceID: UUID, at: Date
    ) async throws -> UUID {
        let created = try await rig.repo.createRun(
            package: package.0, selectedWorkflowID: package.1, workspaceID: workspaceID,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: at)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: at)
        return created.run.id
    }
}
