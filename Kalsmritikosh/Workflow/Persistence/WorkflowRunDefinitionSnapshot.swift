//
//  WorkflowRunDefinitionSnapshot.swift
//  Kalsmritikosh
//
//  PJE-003 — Codable/Hashable snapshot DTOs for the non-Codable PJE-001/002 definition types.
//  These DTOs freeze the exact workflow contract used at run-creation time so that old runs
//  can be reopened against their original definition regardless of subsequent registry changes.
//
//  Non-Codable source types (require DTOs):
//    PersonaWorkflowDefinition, PersonaWorkflowStepDefinition, WorkflowTransitionDefinition,
//    PersonaWorkflowRequirement, PersonaWorkflowValidation, PersonaWorkflowArtifactDefinition,
//    WorkflowCapabilityRequirement, WorkflowSensitiveScopeRequirement,
//    PersonaApplicationDefinition, PersonaToolDefinition, PersonaWorkProductDefinition,
//    ValidatedWorkflowDefinition
//
//  Directly Codable with deterministic encoding (no Sets → used as-is):
//    PersonaObjectSchemaDefinition, PersonaAutomationDefinition
//
//  Needs DTO due to Set<> fields:
//    PersonaValidatorDefinition (supportedStepKinds: Set<WorkflowStepKind>)
//    WorkflowSensitiveScopeRequirement (purposes: Set<SensitiveUsePurpose>)
//
//  PersonaTerminologyDefinition: Codable but uses a TerminologyDefinitionSnapshot for
//  explicit sorted labels rather than relying on Dictionary encoding order.
//

import Foundation

// MARK: - Explicit Equatable + Hashable for Codable-only registry definition types
// These types are in this module but in a different file, so auto-synthesis would
// not work in cross-file extensions. All fields use .rawValue for enum String fields.
// Required so that WorkflowRunContractSnapshot (which stores arrays of these types)
// can auto-synthesize its own Equatable and Hashable conformances.

extension PersonaObjectSchemaDefinition: Equatable {
    public static func == (lhs: PersonaObjectSchemaDefinition, rhs: PersonaObjectSchemaDefinition) -> Bool {
        lhs.id == rhs.id &&
        lhs.version == rhs.version &&
        lhs.label == rhs.label &&
        lhs.representedTypeName == rhs.representedTypeName &&
        lhs.ownership.rawValue == rhs.ownership.rawValue &&
        lhs.detail == rhs.detail
    }
}
extension PersonaObjectSchemaDefinition: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
        hasher.combine(label)
        hasher.combine(representedTypeName)
        hasher.combine(ownership.rawValue)
        hasher.combine(detail)
    }
}

extension PersonaAutomationDefinition: Equatable {
    public static func == (lhs: PersonaAutomationDefinition, rhs: PersonaAutomationDefinition) -> Bool {
        lhs.id == rhs.id &&
        lhs.version == rhs.version &&
        lhs.label == rhs.label &&
        lhs.trigger.rawValue == rhs.trigger.rawValue &&
        lhs.action.rawValue == rhs.action.rawValue &&
        lhs.detail == rhs.detail
    }
}
extension PersonaAutomationDefinition: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
        hasher.combine(label)
        hasher.combine(trigger.rawValue)
        hasher.combine(action.rawValue)
        hasher.combine(detail)
    }
}

// MARK: - Transition snapshot

public struct WorkflowTransitionSnapshot: Codable, Hashable, Sendable {
    public let label: String
    public let targetStepID: String
    public let isReturn: Bool
    public let condition: String?

    public nonisolated init(from t: WorkflowTransitionDefinition) {
        self.label = t.label
        self.targetStepID = t.targetStepID.rawValue
        self.isReturn = t.isReturn
        self.condition = t.condition
    }

    public nonisolated func asTransitionDefinition() -> WorkflowTransitionDefinition {
        WorkflowTransitionDefinition(
            label: label,
            targetStepID: StepDefinitionID(rawValue: targetStepID),
            isReturn: isReturn,
            condition: condition
        )
    }
}

// MARK: - Requirement snapshot

public struct WorkflowRequirementSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let kind: WorkflowRequirementKind
    public let label: String
    public let isBlocking: Bool
    public let detail: String?

    public nonisolated init(from r: PersonaWorkflowRequirement) {
        self.id = r.id
        self.kind = r.kind
        self.label = r.label
        self.isBlocking = r.isBlocking
        self.detail = r.detail
    }

    public nonisolated func asRequirement() -> PersonaWorkflowRequirement {
        PersonaWorkflowRequirement(id: id, kind: kind, label: label, isBlocking: isBlocking, detail: detail)
    }
}

// MARK: - Validation snapshot

public struct WorkflowValidationSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let validatorID: String
    public let label: String
    public let isBlocking: Bool
    public let detail: String?

    public nonisolated init(from v: PersonaWorkflowValidation) {
        self.id = v.id
        self.validatorID = v.validatorID
        self.label = v.label
        self.isBlocking = v.isBlocking
        self.detail = v.detail
    }

    public nonisolated func asValidation() -> PersonaWorkflowValidation {
        PersonaWorkflowValidation(id: id, validatorID: validatorID, label: label, isBlocking: isBlocking, detail: detail)
    }
}

// MARK: - Artifact definition snapshot

public struct WorkflowArtifactDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let workProductTemplateID: String?
    public let isRequired: Bool
    public let detail: String?

    public nonisolated init(from a: PersonaWorkflowArtifactDefinition) {
        self.id = a.id
        self.label = a.label
        self.workProductTemplateID = a.workProductTemplateID
        self.isRequired = a.isRequired
        self.detail = a.detail
    }

    public nonisolated func asArtifactDefinition() -> PersonaWorkflowArtifactDefinition {
        PersonaWorkflowArtifactDefinition(
            id: id, label: label,
            workProductTemplateID: workProductTemplateID,
            isRequired: isRequired, detail: detail
        )
    }
}

// MARK: - Capability requirement snapshot

public struct WorkflowCapabilityRequirementSnapshot: Codable, Hashable, Sendable {
    public let specKey: String
    public let isRequired: Bool
    public let detail: String?

    public nonisolated init(from r: WorkflowCapabilityRequirement) {
        self.specKey = r.specKey
        self.isRequired = r.isRequired
        self.detail = r.detail
    }

    public nonisolated func asCapabilityRequirement() -> WorkflowCapabilityRequirement {
        WorkflowCapabilityRequirement(specKey: specKey, isRequired: isRequired, detail: detail)
    }
}

// MARK: - Sensitive scope requirement snapshot
// Set<SensitiveUsePurpose> → sorted [String] for deterministic encoding.

public struct WorkflowSensitiveScopeRequirementSnapshot: Codable, Hashable, Sendable {
    public let purposes: [String]    // sorted SensitiveUsePurpose.rawValues
    public let detail: String?

    public nonisolated init(from r: WorkflowSensitiveScopeRequirement) {
        self.purposes = r.purposes.map { $0.rawValue }.sorted()
        self.detail = r.detail
    }

    public nonisolated func asSensitiveScopeRequirement() -> WorkflowSensitiveScopeRequirement? {
        let parsed = purposes.compactMap { SensitiveUsePurpose(rawValue: $0) }
        guard parsed.count == purposes.count else { return nil }
        return WorkflowSensitiveScopeRequirement(purposes: Set(parsed), detail: detail)
    }
}

// MARK: - Step definition snapshot

public struct WorkflowStepDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let kind: WorkflowStepKind
    public let label: String
    public let detail: String?
    public let isEntry: Bool
    public let isTerminal: Bool
    public let transitions: [WorkflowTransitionSnapshot]
    public let requirements: [WorkflowRequirementSnapshot]
    public let validations: [WorkflowValidationSnapshot]
    public let artifacts: [WorkflowArtifactDefinitionSnapshot]
    public let sensitiveScope: WorkflowSensitiveScopeRequirementSnapshot?
    public let capabilityRequirements: [WorkflowCapabilityRequirementSnapshot]
    public let decisionBranches: [String]
    public let approverRoles: [String]
    public let loopPolicy: WorkflowLoopPolicy?

    public nonisolated init(from s: PersonaWorkflowStepDefinition) {
        self.id = s.id.rawValue
        self.kind = s.kind
        self.label = s.label
        self.detail = s.detail
        self.isEntry = s.isEntry
        self.isTerminal = s.isTerminal
        self.transitions = s.transitions.map { WorkflowTransitionSnapshot(from: $0) }
        self.requirements = s.requirements.map { WorkflowRequirementSnapshot(from: $0) }
        self.validations = s.validations.map { WorkflowValidationSnapshot(from: $0) }
        self.artifacts = s.artifacts.map { WorkflowArtifactDefinitionSnapshot(from: $0) }
        self.sensitiveScope = s.sensitiveScope.map { WorkflowSensitiveScopeRequirementSnapshot(from: $0) }
        self.capabilityRequirements = s.capabilityRequirements.map { WorkflowCapabilityRequirementSnapshot(from: $0) }
        self.decisionBranches = s.decisionBranches
        self.approverRoles = s.approverRoles
        self.loopPolicy = s.loopPolicy
    }

    public nonisolated func asStepDefinition() -> PersonaWorkflowStepDefinition {
        PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: id),
            kind: kind,
            label: label,
            detail: detail,
            isEntry: isEntry,
            isTerminal: isTerminal,
            transitions: transitions.map { $0.asTransitionDefinition() },
            requirements: requirements.map { $0.asRequirement() },
            validations: validations.map { $0.asValidation() },
            artifacts: artifacts.map { $0.asArtifactDefinition() },
            sensitiveScope: sensitiveScope?.asSensitiveScopeRequirement(),
            capabilityRequirements: capabilityRequirements.map { $0.asCapabilityRequirement() },
            decisionBranches: decisionBranches,
            approverRoles: approverRoles,
            loopPolicy: loopPolicy
        )
    }
}

// MARK: - Workflow definition snapshot

public struct WorkflowDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let schemaVersion: Int
    public let label: String
    public let detail: String?
    public let steps: [WorkflowStepDefinitionSnapshot]
    public let globalRequirements: [WorkflowRequirementSnapshot]
    public let capabilityRequirements: [WorkflowCapabilityRequirementSnapshot]

    public nonisolated init(from d: PersonaWorkflowDefinition) {
        self.id = d.id.rawValue
        self.version = d.version
        self.schemaVersion = d.schemaVersion
        self.label = d.label
        self.detail = d.detail
        self.steps = d.steps.map { WorkflowStepDefinitionSnapshot(from: $0) }
        self.globalRequirements = d.globalRequirements.map { WorkflowRequirementSnapshot(from: $0) }
        self.capabilityRequirements = d.capabilityRequirements.map { WorkflowCapabilityRequirementSnapshot(from: $0) }
    }

    public nonisolated func asWorkflowDefinition() -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: id),
            version: version,
            schemaVersion: schemaVersion,
            label: label,
            detail: detail,
            steps: steps.map { $0.asStepDefinition() },
            globalRequirements: globalRequirements.map { $0.asRequirement() },
            capabilityRequirements: capabilityRequirements.map { $0.asCapabilityRequirement() }
        )
    }
}

// MARK: - Validated workflow definition snapshot
// Set<StepDefinitionID> → sorted [String] for deterministic encoding.

public struct ValidatedWorkflowDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let entryStepID: String
    public let terminalStepIDs: [String]     // sorted StepDefinitionID.rawValues
    public let reachableStepIDs: [String]    // sorted StepDefinitionID.rawValues
    public let definition: WorkflowDefinitionSnapshot

    public nonisolated init(from v: ValidatedWorkflowDefinition) {
        self.id = v.definition.id.rawValue
        self.version = v.definition.version
        self.entryStepID = v.entryStepID.rawValue
        self.terminalStepIDs = v.terminalStepIDs.map { $0.rawValue }.sorted()
        self.reachableStepIDs = v.reachableStepIDs.map { $0.rawValue }.sorted()
        self.definition = WorkflowDefinitionSnapshot(from: v.definition)
    }

    public nonisolated func asValidatedWorkflowDefinition() -> ValidatedWorkflowDefinition {
        ValidatedWorkflowDefinition(
            definition: definition.asWorkflowDefinition(),
            entryStepID: StepDefinitionID(rawValue: entryStepID),
            terminalStepIDs: Set(terminalStepIDs.map { StepDefinitionID(rawValue: $0) }),
            reachableStepIDs: Set(reachableStepIDs.map { StepDefinitionID(rawValue: $0) })
        )
    }
}

// MARK: - Tool definition snapshot

public struct ToolDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let label: String
    public let detail: String?
    public let supportedWorkflowIDs: [String]
    public let capabilityRequirements: [WorkflowCapabilityRequirementSnapshot]

    public nonisolated init(from t: PersonaToolDefinition) {
        self.id = t.id.rawValue
        self.version = t.version
        self.label = t.label
        self.detail = t.detail
        self.supportedWorkflowIDs = t.supportedWorkflowIDs.map { $0.rawValue }
        self.capabilityRequirements = t.capabilityRequirements.map { WorkflowCapabilityRequirementSnapshot(from: $0) }
    }

    public nonisolated func asToolDefinition() -> PersonaToolDefinition {
        PersonaToolDefinition(
            id: ToolDefinitionID(rawValue: id),
            version: version,
            label: label,
            detail: detail,
            supportedWorkflowIDs: supportedWorkflowIDs.map { WorkflowDefinitionID(rawValue: $0) },
            capabilityRequirements: capabilityRequirements.map { $0.asCapabilityRequirement() }
        )
    }
}

// MARK: - Application definition snapshot

public nonisolated struct ApplicationDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let label: String
    public let detail: String?
    public let toolIDs: [String]
    public let workflowIDs: [String]

    public nonisolated init(from a: PersonaApplicationDefinition) {
        self.id = a.id.rawValue
        self.version = a.version
        self.label = a.label
        self.detail = a.detail
        self.toolIDs = a.toolIDs.map { $0.rawValue }
        self.workflowIDs = a.workflowIDs.map { $0.rawValue }
    }

    public nonisolated func asApplicationDefinition() -> PersonaApplicationDefinition {
        PersonaApplicationDefinition(
            id: ApplicationDefinitionID(rawValue: id),
            version: version,
            label: label,
            detail: detail,
            toolIDs: toolIDs.map { ToolDefinitionID(rawValue: $0) },
            workflowIDs: workflowIDs.map { WorkflowDefinitionID(rawValue: $0) }
        )
    }
}

// MARK: - Work product definition snapshot
// WorkProductComposerID is not Codable — store its rawValue string.

public struct WorkProductDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let label: String
    public let template: WorkProductTemplate
    public let requiredComposerIDs: [String]   // WorkProductComposerID.rawValue
    public let requiresCitations: Bool
    public let requiresValidation: Bool
    public let detail: String?

    public nonisolated init(from w: PersonaWorkProductDefinition) {
        self.id = w.id.rawValue
        self.version = w.version
        self.label = w.label
        self.template = w.template
        self.requiredComposerIDs = w.requiredComposerIDs.map { $0.rawValue }
        self.requiresCitations = w.requiresCitations
        self.requiresValidation = w.requiresValidation
        self.detail = w.detail
    }
}

// MARK: - Validator definition snapshot
// Set<WorkflowStepKind> → sorted [String] for deterministic encoding.

public struct ValidatorDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let label: String
    public let supportedStepKinds: [String]    // sorted WorkflowStepKind.rawValues
    public let producesBlockingResults: Bool
    public let detail: String?

    public nonisolated init(from v: PersonaValidatorDefinition) {
        self.id = v.id.rawValue
        self.version = v.version
        self.label = v.label
        self.supportedStepKinds = v.supportedStepKinds.map { $0.rawValue }.sorted()
        self.producesBlockingResults = v.producesBlockingResults
        self.detail = v.detail
    }
}

// MARK: - Terminology snapshot
// [PersonaTerminologyToken: String] → sorted [TerminologyLabelEntry] for canonical encoding.

public struct TerminologyLabelEntry: Codable, Hashable, Sendable {
    public let token: String    // PersonaTerminologyToken.rawValue
    public let label: String

    public nonisolated init(token: String, label: String) {
        self.token = token
        self.label = label
    }
}

public nonisolated struct TerminologyDefinitionSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let applicationID: String
    public let labels: [TerminologyLabelEntry]  // sorted by token
    public let detail: String?

    public nonisolated init(from t: PersonaTerminologyDefinition) {
        self.id = t.id.rawValue
        self.version = t.version
        self.applicationID = t.applicationID.rawValue
        self.labels = t.labels
            .map { TerminologyLabelEntry(token: $0.key.rawValue, label: $0.value) }
            .sorted { $0.token < $1.token }
        self.detail = t.detail
    }
}

// MARK: - WorkflowRunContractSnapshot

/// Frozen canonical snapshot of the entire resolved application package at run-creation time.
/// Stored as JSON with SHA-256 hash. Enables exact reconstruction of any workflow run's
/// original definition regardless of subsequent registry changes.
public nonisolated struct WorkflowRunContractSnapshot: Codable, Hashable, Sendable {

    /// Schema version for this snapshot format. 1 = PJE-003.
    public let snapshotSchemaVersion: Int

    public let applicationKey: RegistryKey<ApplicationDefinitionID>
    public let selectedWorkflowKey: RegistryKey<WorkflowDefinitionID>

    /// Sorted union of all capability spec keys required by tools + workflows + steps.
    public let requiredCapabilitySpecKeys: [String]

    public let application: ApplicationDefinitionSnapshot
    public let tools: [ToolDefinitionSnapshot]
    public let workflows: [ValidatedWorkflowDefinitionSnapshot]
    public let terminology: TerminologyDefinitionSnapshot
    public let objectSchemas: [PersonaObjectSchemaDefinition]
    public let workProducts: [WorkProductDefinitionSnapshot]
    public let validators: [ValidatorDefinitionSnapshot]
    public let automations: [PersonaAutomationDefinition]

    public nonisolated init(
        snapshotSchemaVersion: Int,
        applicationKey: RegistryKey<ApplicationDefinitionID>,
        selectedWorkflowKey: RegistryKey<WorkflowDefinitionID>,
        requiredCapabilitySpecKeys: [String],
        application: ApplicationDefinitionSnapshot,
        tools: [ToolDefinitionSnapshot],
        workflows: [ValidatedWorkflowDefinitionSnapshot],
        terminology: TerminologyDefinitionSnapshot,
        objectSchemas: [PersonaObjectSchemaDefinition],
        workProducts: [WorkProductDefinitionSnapshot],
        validators: [ValidatorDefinitionSnapshot],
        automations: [PersonaAutomationDefinition]
    ) {
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.applicationKey = applicationKey
        self.selectedWorkflowKey = selectedWorkflowKey
        self.requiredCapabilitySpecKeys = requiredCapabilitySpecKeys
        self.application = application
        self.tools = tools
        self.workflows = workflows
        self.terminology = terminology
        self.objectSchemas = objectSchemas
        self.workProducts = workProducts
        self.validators = validators
        self.automations = automations
    }

    /// Build a frozen snapshot from a resolved package and a selected workflow ID.
    /// Throws `WorkflowRunRepositoryError.packageWorkflowNotFound` if the workflow
    /// is not found in the package's workflow list.
    public nonisolated init(
        from package: ResolvedPersonaApplicationPackage,
        selectedWorkflowID: WorkflowDefinitionID
    ) throws {
        guard let selectedValidated = package.workflows.first(where: { $0.definition.id == selectedWorkflowID }) else {
            throw WorkflowRunRepositoryError.packageWorkflowNotFound(selectedWorkflowID)
        }

        // Sorted union of all capability spec keys
        var capKeys = Set<String>()
        for tool in package.tools {
            for req in tool.capabilityRequirements { capKeys.insert(req.specKey) }
        }
        for validated in package.workflows {
            for req in validated.definition.capabilityRequirements { capKeys.insert(req.specKey) }
            for step in validated.definition.steps {
                for req in step.capabilityRequirements { capKeys.insert(req.specKey) }
            }
        }

        let selectedKey = RegistryKey(
            id: selectedWorkflowID,
            version: selectedValidated.definition.version
        )

        self.init(
            snapshotSchemaVersion: 1,
            applicationKey: package.applicationKey,
            selectedWorkflowKey: selectedKey,
            requiredCapabilitySpecKeys: capKeys.sorted(),
            application: ApplicationDefinitionSnapshot(from: package.application),
            tools: package.tools.map { ToolDefinitionSnapshot(from: $0) },
            workflows: package.workflows.map { ValidatedWorkflowDefinitionSnapshot(from: $0) },
            terminology: TerminologyDefinitionSnapshot(from: package.terminology),
            objectSchemas: package.objectSchemas,
            workProducts: package.workProducts.map { WorkProductDefinitionSnapshot(from: $0) },
            validators: package.validators.map { ValidatorDefinitionSnapshot(from: $0) },
            automations: package.automations
        )
    }

    /// Reconstruct the `ValidatedWorkflowDefinition` for the selected workflow key,
    /// exactly as it was at run-creation time.
    public nonisolated func reconstructDefinition() -> ValidatedWorkflowDefinition? {
        workflows.first {
            $0.id == selectedWorkflowKey.id.rawValue && $0.version == selectedWorkflowKey.version
        }?.asValidatedWorkflowDefinition()
    }
}
