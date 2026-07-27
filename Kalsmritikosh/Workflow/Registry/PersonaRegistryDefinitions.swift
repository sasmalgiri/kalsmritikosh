//
//  PersonaRegistryDefinitions.swift
//  Kalsmritikosh
//
//  PJE-002 — Immutable definition types for the six non-workflow registries:
//  object schemas, work products, validators, terminology, and automations.
//
//  PersonaWorkProductDefinition intentionally omits Codable because
//  WorkProductComposerID is not Codable (it is Sendable + Hashable).
//

import Foundation

// MARK: - Object schema ownership

/// Declares how a persona workflow relates to an object type.
/// The schema registry uses this to enforce that canonical ledger objects
/// cannot be duplicated or owned by individual workflows.
public nonisolated enum PersonaObjectSchemaOwnership: String, Codable, CaseIterable, Sendable {
    /// The workflow holds IDs only; the canonical ledger is authoritative.
    case canonicalReferenceOnly
    /// Stage-2 shared professional object (Issue, ProfessionalTask, etc.).
    /// Persona workflow state references it; does not own or copy it.
    case sharedProfessionalReferenceOnly
    /// State created and owned by one workflow run. Not a ledger object.
    case workflowOwned
    /// Brainstorm, hypothesis, scenario, or proposed conclusion — explicitly
    /// not canonical truth and never persisted to the evidence ledger.
    case proposalLayer
}

// MARK: - Object schema definition

public nonisolated struct PersonaObjectSchemaDefinition: VersionedRegistryDefinition, Codable, Sendable {
    public typealias DefinitionID = ObjectSchemaDefinitionID

    public let id: ObjectSchemaDefinitionID
    public let version: Int
    public let label: String
    /// Swift type name this schema represents (used for reserved-name enforcement).
    public let representedTypeName: String
    public let ownership: PersonaObjectSchemaOwnership
    public let detail: String?

    public nonisolated init(
        id: ObjectSchemaDefinitionID,
        version: Int,
        label: String,
        representedTypeName: String,
        ownership: PersonaObjectSchemaOwnership,
        detail: String? = nil
    ) {
        self.id = id; self.version = version; self.label = label
        self.representedTypeName = representedTypeName
        self.ownership = ownership; self.detail = detail
    }
}

// MARK: - Work-product definition

/// Persona-facing descriptor mapping a stable artifact ID to an existing
/// `WorkProductTemplate` and the set of required section composers.
/// Resolves `PersonaWorkflowArtifactDefinition.workProductTemplateID` values.
///
/// Not Codable — `WorkProductComposerID` is not Codable.
public nonisolated struct PersonaWorkProductDefinition: VersionedRegistryDefinition, Sendable {
    public typealias DefinitionID = WorkProductDefinitionID

    public let id: WorkProductDefinitionID
    public let version: Int
    public let label: String
    public let template: WorkProductTemplate
    public let requiredComposerIDs: [WorkProductComposerID]
    public let requiresCitations: Bool
    public let requiresValidation: Bool
    public let detail: String?

    public nonisolated init(
        id: WorkProductDefinitionID,
        version: Int,
        label: String,
        template: WorkProductTemplate,
        requiredComposerIDs: [WorkProductComposerID] = [],
        requiresCitations: Bool = true,
        requiresValidation: Bool = false,
        detail: String? = nil
    ) {
        self.id = id; self.version = version; self.label = label
        self.template = template
        self.requiredComposerIDs = requiredComposerIDs
        self.requiresCitations = requiresCitations
        self.requiresValidation = requiresValidation
        self.detail = detail
    }
}

// MARK: - Validator definition

/// Metadata describing a validator that can be referenced by workflow step validations.
/// Execution context and result evaluation belong to PJE-005.
public nonisolated struct PersonaValidatorDefinition: VersionedRegistryDefinition, Codable, Sendable {
    public typealias DefinitionID = ValidatorDefinitionID

    public let id: ValidatorDefinitionID
    public let version: Int
    public let label: String
    public let supportedStepKinds: Set<WorkflowStepKind>
    public let producesBlockingResults: Bool
    public let detail: String?

    public nonisolated init(
        id: ValidatorDefinitionID,
        version: Int,
        label: String,
        supportedStepKinds: Set<WorkflowStepKind>,
        producesBlockingResults: Bool,
        detail: String? = nil
    ) {
        self.id = id; self.version = version; self.label = label
        self.supportedStepKinds = supportedStepKinds
        self.producesBlockingResults = producesBlockingResults
        self.detail = detail
    }
}

// MARK: - Terminology token

/// Closed set of presentation-only vocabulary tokens that a persona may relabel.
/// The closed enum prevents accidental override of locked evidence vocabulary.
/// Evidence assessments, citation scope, source independence, and export
/// integrity are NOT in this token set and cannot be renamed via terminology packs.
public nonisolated enum PersonaTerminologyToken: String, Codable, CaseIterable, Sendable {
    case application
    case home
    case workspace
    case workflow
    case step
    case issue
    case task
    case deadline
    case attentionItem
    case subject
    case source
    case evidence
    case claim
    case finding
    case observation
    case hypothesis
    case artifact
    case report
    case review
}

// MARK: - Terminology definition

public nonisolated struct PersonaTerminologyDefinition: VersionedRegistryDefinition, Codable, Sendable {
    public typealias DefinitionID = TerminologyDefinitionID

    public let id: TerminologyDefinitionID
    public let version: Int
    /// The application this terminology pack belongs to. Must match the package's application ID.
    public let applicationID: ApplicationDefinitionID
    /// Presentation labels for closed-vocabulary tokens. No blank values permitted.
    public let labels: [PersonaTerminologyToken: String]
    public let detail: String?

    public nonisolated init(
        id: TerminologyDefinitionID,
        version: Int,
        applicationID: ApplicationDefinitionID,
        labels: [PersonaTerminologyToken: String] = [:],
        detail: String? = nil
    ) {
        self.id = id; self.version = version
        self.applicationID = applicationID
        self.labels = labels; self.detail = detail
    }
}

// MARK: - Automation trigger

/// Event kinds that can trigger a persona automation.
public nonisolated enum PersonaAutomationTriggerKind: String, Codable, CaseIterable, Sendable {
    case manual
    case scheduled
    case workflowEvent
    case attentionCreated
}

// MARK: - Automation action (restricted)

/// Closed set of safe, non-human-decision automation actions.
///
/// Actions that confirm claims, resolve contradictions, approve evidence,
/// record human decisions, mark privilege, approve publication, complete workflows,
/// or finalize work products are intentionally absent — they cannot be represented,
/// not merely rejected at a later validation boundary.
public nonisolated enum PersonaAutomationActionKind: String, Codable, CaseIterable, Sendable {
    case createSuggestion
    case createCandidateTask
    case createCandidateDeadline
    case createReviewQueueItem
    case createMissingEvidenceRequest
    case createAttentionItem
}

// MARK: - Automation definition

public nonisolated struct PersonaAutomationDefinition: VersionedRegistryDefinition, Codable, Sendable {
    public typealias DefinitionID = AutomationDefinitionID

    public let id: AutomationDefinitionID
    public let version: Int
    public let label: String
    public let trigger: PersonaAutomationTriggerKind
    public let action: PersonaAutomationActionKind
    public let detail: String?

    public nonisolated init(
        id: AutomationDefinitionID,
        version: Int,
        label: String,
        trigger: PersonaAutomationTriggerKind,
        action: PersonaAutomationActionKind,
        detail: String? = nil
    ) {
        self.id = id; self.version = version; self.label = label
        self.trigger = trigger; self.action = action; self.detail = detail
    }
}
