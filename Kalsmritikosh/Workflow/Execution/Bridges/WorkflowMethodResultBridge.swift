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
