//
//  WorkflowMethodResultBridge.swift
//  Kalsmritikosh
//
//  PJE-006C — Method adapter boundary types.
//
//  Stage 3 records that a method result was produced OUTSIDE or AHEAD of the
//  future Stage 4 Professional Method Engine. There is deliberately no
//  ProfessionalMethodDefinition, MethodRun, MethodNode, MethodEdge, Five Whys,
//  Fishbone, root-cause assessment, CAPA, or Decision Matrix here — the method
//  step is an adapter, and these types are reference envelopes only.
//
//  A method result is NOT automatically a Claim, NOT automatically a root cause,
//  and is never labelled a confirmed fact by any Stage 3 executor.
//

import Foundation

// MARK: - Provenance reference

/// A pointer from a method result (or an effectiveness observation) to a
/// canonical object. Kind strings use the WorkflowEvidenceObjectKind vocabulary
/// and are gate-verified where they enter workflow state.
public nonisolated struct WorkflowMethodProvenanceReference: Codable, Hashable, Sendable {
    public let objectKind: String
    public let canonicalObjectID: String

    public nonisolated init(objectKind: String, canonicalObjectID: String) {
        self.objectKind = objectKind
        self.canonicalObjectID = canonicalObjectID
    }
}

// MARK: - Method result reference

/// The externally produced method result a `method` step records.
/// All identity fields are nonblank; provenance is explicit; the summary is
/// workflow-owned narrative, never canonical text.
public nonisolated struct WorkflowMethodResultReference: Codable, Hashable, Sendable {
    public let providerID: String
    public let providerVersion: String

    public let methodDefinitionID: String
    public let methodRunReferenceID: String
    public let resultReferenceID: String

    public let summary: String

    public let provenanceReferences: [WorkflowMethodProvenanceReference]

    public let completedBy: String
    public let completedAt: Date

    public let limitations: [String]

    public nonisolated init(
        providerID: String,
        providerVersion: String,
        methodDefinitionID: String,
        methodRunReferenceID: String,
        resultReferenceID: String,
        summary: String,
        provenanceReferences: [WorkflowMethodProvenanceReference],
        completedBy: String,
        completedAt: Date,
        limitations: [String]
    ) {
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.methodDefinitionID = methodDefinitionID
        self.methodRunReferenceID = methodRunReferenceID
        self.resultReferenceID = resultReferenceID
        self.summary = summary
        self.provenanceReferences = provenanceReferences
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.limitations = limitations
    }

    /// Fail-closed structural validation: every identity field nonblank,
    /// summary nonblank, completedBy nonblank, provenance explicit (nonempty).
    public nonisolated func validateStructure() throws {
        func requireNonblank(_ value: String, _ field: String) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: field, reason: "\(field) must not be blank")
            }
        }
        try requireNonblank(providerID, "providerID")
        try requireNonblank(providerVersion, "providerVersion")
        try requireNonblank(methodDefinitionID, "methodDefinitionID")
        try requireNonblank(methodRunReferenceID, "methodRunReferenceID")
        try requireNonblank(resultReferenceID, "resultReferenceID")
        try requireNonblank(summary, "summary")
        try requireNonblank(completedBy, "completedBy")
        guard !provenanceReferences.isEmpty else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "provenanceReferences",
                reason: "A method result must declare explicit provenance")
        }
    }
}

// MARK: - PM-003 registered-method reference envelopes
//
// These are REFERENCE ENVELOPES ONLY for the v2 registered-method step: an exact
// method-definition selection, an exact linked-MethodRun reference, and an exact
// completed-result reference whose provenance is DERIVED by the bridge from
// persisted method evidence links (never caller-supplied). No Stage-4 domain type
// (ProfessionalMethodDefinition / MethodRun / node / edge / finding / repository)
// is declared or copied here.

/// An exact professional-method selection: a definition id + an explicit version.
/// "Latest" is never persisted — the version is always concrete.
public nonisolated struct WorkflowProfessionalMethodSelection: Codable, Hashable, Sendable {
    public let methodDefinitionID: String
    public let methodDefinitionVersion: Int

    public nonisolated init(methodDefinitionID: String, methodDefinitionVersion: Int) {
        self.methodDefinitionID = methodDefinitionID
        self.methodDefinitionVersion = methodDefinitionVersion
    }

    public nonisolated func validateStructure() throws {
        guard !methodDefinitionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              methodDefinitionID == methodDefinitionID.trimmingCharacters(in: .whitespaces) else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "methodDefinitionID", reason: "Method definition id must be nonblank and trim-stable")
        }
        guard methodDefinitionVersion >= 1 else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "methodDefinitionVersion", reason: "Method definition version must be at least 1")
        }
    }
}

/// An exact reference to a persisted, linked MethodRun. IDs only.
public nonisolated struct WorkflowProfessionalMethodRunReference: Codable, Hashable, Sendable {
    public let methodRunID: UUID
    public let methodDefinitionID: String
    public let methodDefinitionVersion: Int

    public nonisolated init(methodRunID: UUID, methodDefinitionID: String, methodDefinitionVersion: Int) {
        self.methodRunID = methodRunID
        self.methodDefinitionID = methodDefinitionID
        self.methodDefinitionVersion = methodDefinitionVersion
    }
}

/// An exact completed-result reference. Still a workflow reference snapshot —
/// never a Claim, evidence object, or professional approval. Its provenance is
/// derived solely from persisted method evidence links by the bridge.
public nonisolated struct WorkflowProfessionalMethodResultReference: Codable, Hashable, Sendable {
    public let run: WorkflowProfessionalMethodRunReference
    public let completedRevision: Int
    public let summary: String
    public let provenanceReferences: [WorkflowMethodProvenanceReference]
    public let completedBy: String
    public let completedAt: Date
    public let limitations: [String]

    public nonisolated init(
        run: WorkflowProfessionalMethodRunReference,
        completedRevision: Int,
        summary: String,
        provenanceReferences: [WorkflowMethodProvenanceReference],
        completedBy: String,
        completedAt: Date,
        limitations: [String]
    ) {
        self.run = run
        self.completedRevision = completedRevision
        self.summary = summary
        self.provenanceReferences = provenanceReferences
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.limitations = limitations
    }

    public nonisolated func validateStructure() throws {
        guard completedRevision >= 1 else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "completedRevision", reason: "Completed revision must be at least 1")
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "summary", reason: "summary must not be blank")
        }
        guard !completedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "completedBy", reason: "completedBy must not be blank")
        }
        guard !provenanceReferences.isEmpty else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "provenanceReferences",
                reason: "A completed method result must declare explicit provenance")
        }
        for reference in provenanceReferences {
            guard WorkflowEvidenceObjectKind(rawValue: reference.objectKind) != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "provenanceReferences", reason: "Unknown canonical object kind '\(reference.objectKind)'")
            }
            guard UUID(uuidString: reference.canonicalObjectID) != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "provenanceReferences", reason: "Not a valid canonical object UUID")
            }
        }
    }
}

// MARK: - Read-only resolver protocol exposed to Stage 3

/// The narrow, read-only surface the v2 registered-method executor depends on.
/// The executor holds ONLY this protocol — never a Database, MethodRunRepository,
/// ProfessionalMethodRegistry, or SQL. The concrete resolver is the Stage-4
/// ProfessionalMethodWorkflowBridge.
public protocol WorkflowProfessionalMethodRunResolving: Sendable {
    /// Verify a selection resolves to an exact registered definition.
    func validateSelection(_ selection: WorkflowProfessionalMethodSelection) async throws

    /// Verify a persisted MethodRun matches the selection + the exact workflow
    /// invocation back-references and is not terminal; returns its exact reference.
    func validateLinkedRun(
        runID: UUID,
        selection: WorkflowProfessionalMethodSelection,
        workspaceID: UUID,
        workflowRunID: UUID,
        workflowStepRunID: UUID
    ) async throws -> WorkflowProfessionalMethodRunReference

    /// Build a completed-result reference from a COMPLETED MethodRun, deriving
    /// provenance solely from its persisted evidence links (fail-closed via the
    /// shared canonical gate). Never mutates any canonical or method row.
    func completedResult(
        runID: UUID,
        selection: WorkflowProfessionalMethodSelection,
        workspaceID: UUID,
        workflowRunID: UUID,
        workflowStepRunID: UUID,
        summary: String,
        completedBy: String,
        limitations: [String]
    ) async throws -> WorkflowProfessionalMethodResultReference
}
