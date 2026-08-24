//
//  WorkflowProvenanceModel.swift
//  Kalsmritikosh
//
//  PJE-007 — Evidence, Attachment and Provenance Bridge: the model vocabulary.
//
//  The bridge invariant:
//    workflow state or output → exact producing executor/action →
//    exact canonical input references → exact source versions/locators where
//    available → current access-policy enforcement.
//
//  Nothing here copies canonical evidence into workflow tables, promotes
//  workflow notes into Claims, or infers provenance from display text.
//

import Foundation

// MARK: - Semantics (version-aware, like state_hash_semantics)

/// Which provenance contract a persisted workflow row satisfies.
/// `legacyUntracked` rows reopen without a snapshot, are never rewritten by
/// reopening, never receive guessed provenance, and upgrade only on a
/// legitimate mutation.
public enum WorkflowProvenanceSemantics: String, Codable, Sendable, CaseIterable, Equatable {
    case legacyUntracked
    case snapshotV1
}

// MARK: - Owner vocabulary

public enum WorkflowProvenanceOwnerKind: String, Codable, CaseIterable, Sendable {
    case stepState
    case artifact
    case decision
}

/// Typed owner handle for inspection.
public enum WorkflowProvenanceOwner: Sendable, Equatable {
    case stepRun(UUID)
    case artifact(UUID)
    case decision(UUID)

    public nonisolated var kind: WorkflowProvenanceOwnerKind {
        switch self {
        case .stepRun:  return .stepState
        case .artifact: return .artifact
        case .decision: return .decision
        }
    }

    public nonisolated var id: UUID {
        switch self {
        case .stepRun(let id), .artifact(let id), .decision(let id): return id
        }
    }
}

// MARK: - Reference vocabulary

/// The first eight are canonical evidence/object references; `workflowArtifact`
/// and `workProductRun` are workflow-output dependencies, not canonical evidence.
public enum WorkflowProvenanceReferenceKind: String, Codable, CaseIterable, Sendable {
    case claim
    case evidenceBlock
    case sourceVersion
    case entity
    case event
    case issue
    case gap
    case contradiction

    case workflowArtifact
    case workProductRun

    /// The matching evidence-gate kind for canonical references; nil for
    /// workflow-output kinds.
    public nonisolated var evidenceGateKind: WorkflowEvidenceObjectKind? {
        WorkflowEvidenceObjectKind(rawValue: rawValue)
    }
}

// MARK: - Role / disposition vocabulary (workflow vocabulary — NOT evidence status)

public enum WorkflowProvenanceRole: String, Codable, CaseIterable, Sendable {
    case selected
    case reviewed
    case supporting
    case contradicting
    case contextual

    case calculationInput
    case methodInput
    case decisionBasis

    case attachmentSource
    case generatedFrom
    case outputCitation
}

public enum WorkflowProvenanceDisposition: String, Codable, CaseIterable, Sendable {
    case active
    case excludedFromWorkflow
    case needsFollowUp
}

// MARK: - Provenance reference

/// One ordered reference inside a snapshot. IDs are the REAL supplied IDs —
/// decoding never substitutes replacement UUIDs. Label and note are workflow
/// annotations, never evidence content.
public nonisolated struct WorkflowProvenanceReference: Codable, Hashable, Sendable {
    public let kind: WorkflowProvenanceReferenceKind
    public let canonicalObjectID: UUID
    public let role: WorkflowProvenanceRole
    public let disposition: WorkflowProvenanceDisposition
    public let sourceVersionID: UUID?
    public let locatorJSON: String?
    public let label: String?
    public let note: String?

    public nonisolated init(
        kind: WorkflowProvenanceReferenceKind,
        canonicalObjectID: UUID,
        role: WorkflowProvenanceRole,
        disposition: WorkflowProvenanceDisposition = .active,
        sourceVersionID: UUID? = nil,
        locatorJSON: String? = nil,
        label: String? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.canonicalObjectID = canonicalObjectID
        self.role = role
        self.disposition = disposition
        self.sourceVersionID = sourceVersionID
        self.locatorJSON = locatorJSON
        self.label = label
        self.note = note
    }

    /// Structural validation: locatorJSON, when present, must be valid JSON.
    public nonisolated func validateStructure() throws {
        if let locator = locatorJSON {
            guard let data = locator.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw WorkflowProvenanceError.invalidLocatorJSON
            }
        }
    }
}

// MARK: - Provenance snapshot

/// The persisted-and-hashed provenance record for one owner (step state,
/// artifact, or decision). Reference order is deterministic and semantically
/// meaningful.
public nonisolated struct WorkflowProvenanceSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let ownerKind: WorkflowProvenanceOwnerKind
    public let workflowRunID: UUID
    public let ownerID: UUID
    public let workflowRunRevision: Int
    public let producerID: String
    public let producerVersion: String
    public let sourceStateSHA256: String?
    public let references: [WorkflowProvenanceReference]

    public nonisolated init(
        ownerKind: WorkflowProvenanceOwnerKind,
        workflowRunID: UUID,
        ownerID: UUID,
        workflowRunRevision: Int,
        producerID: String,
        producerVersion: String,
        sourceStateSHA256: String?,
        references: [WorkflowProvenanceReference]
    ) {
        self.schemaVersion = 1
        self.ownerKind = ownerKind
        self.workflowRunID = workflowRunID
        self.ownerID = ownerID
        self.workflowRunRevision = workflowRunRevision
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.sourceStateSHA256 = sourceStateSHA256
        self.references = references
    }

    /// Structural validation: nonblank producer identity; step-state owners
    /// carry a mandatory source-state hash; every reference is structurally valid.
    public nonisolated func validateStructure() throws {
        guard !producerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !producerVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowProvenanceError.invalidProducerIdentity
        }
        if ownerKind == .stepState {
            guard let sha = sourceStateSHA256,
                  !sha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowProvenanceError.snapshotStateHashMismatch(ownerID)
            }
        }
        for reference in references {
            try reference.validateStructure()
        }
    }
}

// MARK: - Producer identities (non-executor producers)

/// Stable producer identities for provenance snapshots not produced by a step
/// executor. Step-state snapshots use the exact executor ID/version instead.
public enum WorkflowProvenanceProducers {
    public static nonisolated let lifecycleID = "com.kalsmritikosh.workflow.lifecycle"
    public static nonisolated let lifecycleVersion = "1"
    public static nonisolated let decisionID = "com.kalsmritikosh.workflow.lifecycle.decision"
    public static nonisolated let decisionVersion = "1"
    public static nonisolated let workProductAssemblyID = "com.kalsmritikosh.workflow.work-product-assembly"
    public static nonisolated let workProductAssemblyVersion = "1"
    public static nonisolated let attachmentID = "com.kalsmritikosh.workflow.attachment"
    public static nonisolated let attachmentVersion = "1"
}

// MARK: - Errors

public enum WorkflowProvenanceError: Error, Equatable, Sendable {
    case snapshotMissing(ownerKind: WorkflowProvenanceOwnerKind, ownerID: UUID)
    case snapshotHashMismatch(UUID)
    case snapshotOwnerMismatch(UUID)
    case snapshotStateHashMismatch(UUID)

    case referenceCountMismatch(UUID)
    case referenceOrdinalGap(UUID)
    case referenceRowMismatch(UUID)

    case referenceDenied(kind: WorkflowProvenanceReferenceKind, id: UUID)
    case canonicalTargetNotFound(kind: WorkflowProvenanceReferenceKind, id: UUID)
    case crossWorkspaceReference(kind: WorkflowProvenanceReferenceKind, id: UUID)

    case attachmentSourceVersionNotFound(UUID)
    case attachmentLogicalSourceMismatch(UUID)
    case attachmentHashMismatch(UUID)
    case attachmentRelationMismatch(UUID)
    case attachmentAccessDenied(UUID)

    case artifactDefinitionNotFound(String)
    case artifactKindMismatch(UUID)

    case invalidLocatorJSON
    case invalidProducerIdentity
    case legacyProvenanceUnavailable(UUID)
}
