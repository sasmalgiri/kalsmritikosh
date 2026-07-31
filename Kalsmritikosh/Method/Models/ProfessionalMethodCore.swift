//
//  ProfessionalMethodCore.swift
//  Kalsmritikosh
//
//  PM-001 — Professional Method Core Contract (Stage 4).
//
//  The shared, persona-neutral domain contract every concrete professional
//  method (Five Whys, Fishbone, Hypothesis Matrix, Root-Cause Assessment, CAPA,
//  Risk/Decision Matrix, …) will build on. This file defines DOMAIN MODELS ONLY —
//  no algorithms, no persistence, no registry, no UI, no LLM. Persistence lands
//  in PM-002 (schema v79 + repositories); the registry + Stage-3 adapter bridge
//  lands in PM-003.
//
//  These types live under Kalsmritikosh/Method/ — a NEW Stage-4 subsystem OUTSIDE
//  Stage 3's directories (Workflow/, Storage/, Core/Models/). The PJE-008 /
//  PJE-006C boundary guards forbid declaring Stage-4 method types inside Stage 3;
//  keeping them here honours that boundary while letting Stage 4 begin.
//
//  Core truth boundaries this contract preserves:
//    working method state ≠ canonical evidence
//    method finding      ≠ confirmed Claim
//    assumption          ≠ fact
//    candidate cause     ≠ root cause
//    method completion   ≠ professional correctness
//    method review status≠ evidence status
//
//  Method working state, support, and review vocabularies are PROPOSAL-LAYER and
//  intentionally distinct from the evidence-status vocabularies in
//  Core/Models (EvidenceAssessment / EvidenceStatus / FactStatus / ReviewDisposition).
//  Canonical evidence references reuse the PJE-007 `WorkflowProvenanceReferenceKind`
//  vocabulary and are IDs only — this contract never copies evidence content.
//

import Foundation

// MARK: - Stable typed identifiers (string-backed, versioned by a separate field)

/// Stable reverse-domain identity for a professional method definition
/// (e.g. `"com.kalsmritikosh.method.five-whys"`). Deliberately not Comparable
/// (avoids MainActor-isolated retroactive conformances under Swift 6 strict
/// concurrency), matching the Stage-3 stable-ID idiom.
public nonisolated struct ProfessionalMethodDefinitionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// A method-declared node kind (e.g. `"cause"`, `"hypothesis"`, `"whyStep"`).
/// The core contract stays generic — concrete methods declare their own kinds;
/// the core never enumerates them.
public nonisolated struct MethodNodeKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// A method-declared edge kind (e.g. `"leadsTo"`, `"contributesTo"`, `"refutes"`).
public nonisolated struct MethodEdgeKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// A required input role a method declares (e.g. `"problemStatement"`,
/// `"evidenceSet"`). Generic — concrete methods define their own roles.
public nonisolated struct MethodInputRole: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// A method-declared finding kind (e.g. `"candidateCause"`, `"recommendation"`).
public nonisolated struct MethodFindingKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Proposal-layer vocabularies (NOT evidence status)

/// The working state of a method node. This is PROPOSAL-LAYER method vocabulary,
/// intentionally distinct from any evidence-status enum. A node's working state
/// never asserts that its content is canonical truth.
public nonisolated enum MethodWorkingState: String, Codable, Sendable, Hashable, CaseIterable {
    case proposal
    case ruleSupported
    case disputed
    case gap
    case humanRejected
    case humanAcceptedForWorkflow
}

/// How strongly a method finding is supported WITHIN the method process. This is
/// a method-analytical judgement, never an evidentiary-certainty claim.
public nonisolated enum MethodFindingSupportStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case unsupported
    case partiallySupported
    case supported
    case contradicted
}

/// The method-review status of a node/finding. Method review status is NOT
/// evidence status: accepting a finding for the workflow does not confirm it as
/// a Claim.
public nonisolated enum MethodReviewStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case unreviewed
    case acceptedForWorkflow
    case rejected
    case needsRevision
}

/// The status of an explicit method assumption. An assumption is never silently
/// converted into a fact.
public nonisolated enum MethodAssumptionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case open
    case accepted
    case rejected
    case needsEvidence
}

/// The analytical role an evidence link plays for a node — method structure, not
/// canonical claim polarity.
public nonisolated enum MethodEvidenceLinkRole: String, Codable, Sendable, Hashable, CaseIterable {
    case supporting
    case contradicting
    case contextual
}

/// A neutral method category. Categories group methods; they are not engines.
public nonisolated enum MethodCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case analysis
    case causal
    case planning
    case assessment
    case decision
    case review
}

/// One human review action recorded against a method run/node/finding.
public nonisolated enum MethodReviewAction: String, Codable, Sendable, Hashable, CaseIterable {
    case acceptForWorkflow
    case reject
    case requestRevision
    case comment
    case reopen
}

/// Severity of a deterministic method validation result.
public nonisolated enum MethodValidationSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case info
    case warning
    case error
    /// A blocking result prevents method completion. It never CONFIRMS a conclusion.
    case blocking
}

/// What a validation result is about.
public nonisolated enum MethodValidationSubjectKind: String, Codable, Sendable, Hashable, CaseIterable {
    case run
    case node
    case edge
    case assumption
    case finding
    case evidenceLink
}

/// Lifecycle status of a persistent method execution. `completed` means the
/// method PROCESS finished — it does not confirm the result as truth.
public nonisolated enum MethodRunStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case draft
    case active
    case waitingForHuman
    case blocked
    case completed
    case cancelled
    case superseded
}

// MARK: - Definition (immutable, versioned — describes a method, holds no run state)

/// A required review a method declares in its contract.
public nonisolated struct MethodRequiredReview: Codable, Sendable, Hashable {
    public let reviewKey: String
    public let label: String
    /// When true, the review may only be satisfied by a human actor.
    public let mustBeHuman: Bool

    public nonisolated init(reviewKey: String, label: String, mustBeHuman: Bool = true) {
        self.reviewKey = reviewKey
        self.label = label
        self.mustBeHuman = mustBeHuman
    }
}

/// The output contract a method promises. A method may produce findings and,
/// separately, feed a work-product template — it never confirms Claims.
public nonisolated struct MethodOutputContract: Codable, Sendable, Hashable {
    public let allowedFindingKinds: [MethodFindingKind]
    public let mayProduceWorkProduct: Bool

    public nonisolated init(allowedFindingKinds: [MethodFindingKind], mayProduceWorkProduct: Bool = false) {
        self.allowedFindingKinds = allowedFindingKinds
        self.mayProduceWorkProduct = mayProduceWorkProduct
    }
}

/// Immutable, versioned metadata describing a professional method. Contains NO
/// run state (no status, revision, nodes, findings) — those live on `MethodRun`
/// and its children.
public nonisolated struct ProfessionalMethodDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: ProfessionalMethodDefinitionID
    public let version: Int
    public let label: String
    public let category: MethodCategory
    public let requiredInputRoles: [MethodInputRole]
    public let allowedNodeKinds: [MethodNodeKind]
    public let allowedEdgeKinds: [MethodEdgeKind]
    public let requiredReviews: [MethodRequiredReview]
    public let validationIdentifiers: [String]
    public let outputContract: MethodOutputContract

    public nonisolated init(
        id: ProfessionalMethodDefinitionID,
        version: Int,
        label: String,
        category: MethodCategory,
        requiredInputRoles: [MethodInputRole] = [],
        allowedNodeKinds: [MethodNodeKind] = [],
        allowedEdgeKinds: [MethodEdgeKind] = [],
        requiredReviews: [MethodRequiredReview] = [],
        validationIdentifiers: [String] = [],
        outputContract: MethodOutputContract
    ) {
        self.id = id
        self.version = version
        self.label = label
        self.category = category
        self.requiredInputRoles = requiredInputRoles
        self.allowedNodeKinds = allowedNodeKinds
        self.allowedEdgeKinds = allowedEdgeKinds
        self.requiredReviews = requiredReviews
        self.validationIdentifiers = validationIdentifiers
        self.outputContract = outputContract
    }

    /// Structural validation: nonblank stable id + label, version ≥ 1, no blank
    /// node/edge/input keys. Called by the PM-003 registry before acceptance.
    public nonisolated func validateStructure() throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MethodContractError.blankDefinitionID
        }
        guard version >= 1 else { throw MethodContractError.invalidDefinitionVersion }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MethodContractError.blankDefinitionLabel
        }
        let blankKey =
            allowedNodeKinds.contains { $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || allowedEdgeKinds.contains { $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || requiredInputRoles.contains { $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blankKey else { throw MethodContractError.blankMethodKey }
    }
}

// MARK: - Run + working graph

/// One persistent execution of a method. Mirrors the Stage-3 run idiom
/// (revision for optimistic CAS, supersededByRunID for append-only supersession)
/// without depending on Stage-3 workflow types beyond optional back-references.
public nonisolated struct MethodRun: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let workspaceID: UUID
    public let methodDefinitionID: ProfessionalMethodDefinitionID
    public let methodDefinitionVersion: Int
    /// Optional back-references to the invoking Stage-3 workflow (the Stage-3
    /// `.method` step stores only a MethodRun reference — see PM-003 bridge).
    public let workflowRunID: UUID?
    public let workflowStepRunID: UUID?
    public let status: MethodRunStatus
    public let title: String?
    public let revision: Int
    public let createdBy: String
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let supersededByRunID: UUID?

    public nonisolated init(
        id: UUID = UUID(),
        workspaceID: UUID,
        methodDefinitionID: ProfessionalMethodDefinitionID,
        methodDefinitionVersion: Int,
        workflowRunID: UUID? = nil,
        workflowStepRunID: UUID? = nil,
        status: MethodRunStatus,
        title: String? = nil,
        revision: Int,
        createdBy: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        supersededByRunID: UUID? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.methodDefinitionID = methodDefinitionID
        self.methodDefinitionVersion = methodDefinitionVersion
        self.workflowRunID = workflowRunID
        self.workflowStepRunID = workflowStepRunID
        self.status = status
        self.title = title
        self.revision = revision
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.supersededByRunID = supersededByRunID
    }
}

/// A generic working item inside a method run. Its `workingState` is proposal
/// layer — a node never mutates a Claim.
public nonisolated struct MethodNode: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let nodeDefinitionKey: String
    public let nodeKind: MethodNodeKind
    public let label: String
    public let body: String?
    public let workingState: MethodWorkingState
    public let ordinal: Int
    public let parentNodeID: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        nodeDefinitionKey: String,
        nodeKind: MethodNodeKind,
        label: String,
        body: String? = nil,
        workingState: MethodWorkingState = .proposal,
        ordinal: Int,
        parentNodeID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.nodeDefinitionKey = nodeDefinitionKey
        self.nodeKind = nodeKind
        self.label = label
        self.body = body
        self.workingState = workingState
        self.ordinal = ordinal
        self.parentNodeID = parentNodeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A typed relationship between two method nodes. Expresses method structure,
/// not a canonical graph relationship.
public nonisolated struct MethodEdge: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let fromNodeID: UUID
    public let toNodeID: UUID
    public let edgeKind: MethodEdgeKind
    public let label: String?
    public let ordinal: Int

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        fromNodeID: UUID,
        toNodeID: UUID,
        edgeKind: MethodEdgeKind,
        label: String? = nil,
        ordinal: Int
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.edgeKind = edgeKind
        self.label = label
        self.ordinal = ordinal
    }
}

// MARK: - Evidence links (canonical references — IDs only, reuse PJE-007 vocabulary)

/// Links a method node to exact canonical evidence. `targetKind` REUSES the
/// PJE-007 `WorkflowProvenanceReferenceKind` vocabulary; `targetID` is a
/// canonical ID only — this contract never copies evidence content.
public nonisolated struct MethodEvidenceLink: Codable, Sendable, Hashable {
    public let methodRunID: UUID
    public let nodeID: UUID?
    public let targetKind: WorkflowProvenanceReferenceKind
    public let targetID: UUID
    public let role: MethodEvidenceLinkRole
    public let ordinal: Int
    public let addedBy: String
    public let addedAt: Date

    public nonisolated init(
        methodRunID: UUID,
        nodeID: UUID? = nil,
        targetKind: WorkflowProvenanceReferenceKind,
        targetID: UUID,
        role: MethodEvidenceLinkRole,
        ordinal: Int,
        addedBy: String,
        addedAt: Date
    ) {
        self.methodRunID = methodRunID
        self.nodeID = nodeID
        self.targetKind = targetKind
        self.targetID = targetID
        self.role = role
        self.ordinal = ordinal
        self.addedBy = addedBy
        self.addedAt = addedAt
    }
}

// MARK: - Assumptions + findings

/// An explicit proposal-layer assumption. Never silently converted into a Claim.
public nonisolated struct MethodAssumption: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let nodeID: UUID?
    public let statement: String
    public let status: MethodAssumptionStatus
    public let rationale: String?
    public let createdBy: String
    public let reviewedBy: String?
    public let reviewedAt: Date?

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        nodeID: UUID? = nil,
        statement: String,
        status: MethodAssumptionStatus = .open,
        rationale: String? = nil,
        createdBy: String,
        reviewedBy: String? = nil,
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.nodeID = nodeID
        self.statement = statement
        self.status = status
        self.rationale = rationale
        self.createdBy = createdBy
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
    }
}

/// A method-produced finding CANDIDATE. It is not canonical truth. It may
/// REFERENCE an existing Claim (`relatedClaimID`) or later become the basis of a
/// separately reviewed Claim operation — but this type never IS a Claim.
public nonisolated struct MethodFinding: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let nodeID: UUID?
    public let statement: String
    public let findingKind: MethodFindingKind
    public let supportStatus: MethodFindingSupportStatus
    public let reviewStatus: MethodReviewStatus
    /// A reference to an existing canonical Claim, when the finding relates to
    /// one. Never a promotion — the finding is not confirmed by carrying this ID.
    public let relatedClaimID: UUID?
    public let createdAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        nodeID: UUID? = nil,
        statement: String,
        findingKind: MethodFindingKind,
        supportStatus: MethodFindingSupportStatus = .unsupported,
        reviewStatus: MethodReviewStatus = .unreviewed,
        relatedClaimID: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.nodeID = nodeID
        self.statement = statement
        self.findingKind = findingKind
        self.supportStatus = supportStatus
        self.reviewStatus = reviewStatus
        self.relatedClaimID = relatedClaimID
        self.createdAt = createdAt
    }
}

// MARK: - Review (append-only, human-only) + validation

/// One append-only human review action. The system, model, executor and
/// automation cannot record a human review — `validate()` enforces a human actor
/// with a non-blank identifier. Reuses the Stage-3 `WorkflowDecisionActorKind`.
public nonisolated struct MethodReview: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let nodeID: UUID?
    public let findingID: UUID?
    public let action: MethodReviewAction
    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String
    public let comment: String?
    public let reviewedAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        nodeID: UUID? = nil,
        findingID: UUID? = nil,
        action: MethodReviewAction,
        actorKind: WorkflowDecisionActorKind = .human,
        actorIdentifier: String,
        comment: String? = nil,
        reviewedAt: Date
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.nodeID = nodeID
        self.findingID = findingID
        self.action = action
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
        self.comment = comment
        self.reviewedAt = reviewedAt
    }

    /// A method review is a HUMAN act: only `.human` actors with a non-blank
    /// identifier may record one. The PM-002 repository calls this before insert.
    public nonisolated func validate() throws {
        guard actorKind == .human else { throw MethodContractError.reviewRequiresHumanActor }
        guard !actorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MethodContractError.blankReviewActorIdentifier
        }
    }
}

/// A persisted deterministic validation result. May block method completion
/// (severity `.blocking`); it never confirms a professional conclusion.
public nonisolated struct MethodValidationResult: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let methodRunID: UUID
    public let validatorID: String
    public let validatorVersion: String
    public let severity: MethodValidationSeverity
    public let code: String
    public let message: String
    public let subjectKind: MethodValidationSubjectKind
    public let subjectID: UUID?
    public let createdAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        methodRunID: UUID,
        validatorID: String,
        validatorVersion: String,
        severity: MethodValidationSeverity,
        code: String,
        message: String,
        subjectKind: MethodValidationSubjectKind,
        subjectID: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.methodRunID = methodRunID
        self.validatorID = validatorID
        self.validatorVersion = validatorVersion
        self.severity = severity
        self.code = code
        self.message = message
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.createdAt = createdAt
    }

    /// Whether this result must block method completion.
    public nonisolated var blocksCompletion: Bool { severity == .blocking }
}

// MARK: - Errors

public nonisolated enum MethodContractError: Error, Equatable, Sendable {
    case blankDefinitionID
    case blankDefinitionLabel
    case invalidDefinitionVersion
    case blankMethodKey
    case reviewRequiresHumanActor
    case blankReviewActorIdentifier
}
