//
//  WorkflowDefinition.swift
//  Kalsmritikosh
//
//  PJE-001 — Workflow Definition Contract (Stage 3: Persona Job Engine).
//
//  Immutable definition layer: application, tool, workflow, step, transition,
//  requirement, validation, artifact, capability, and sensitive-scope declarations.
//  No schema change — persistence is PJE-003 (schema v75).
//  No run types, registries, or executors — those are PJE-002 through PJE-006.
//
//  Definitions are immutable once published. A workflow run binds to an exact
//  definition ID + version and stores a frozen JSON snapshot (PJE-003). Changing a
//  registered definition does not alter any existing run.
//
//  Personas may rename presentation concepts via the terminology registry (PJE-002)
//  but must not redefine canonical evidence-status values, citation scope, source
//  independence, or export integrity through definition-layer terminology overrides.
//

import Foundation

// MARK: - Stable typed definition IDs

/// Stable, string-backed identity for a persona application definition.
/// Reverse-domain convention: `"com.kalsmritikosh.investigator"`.
public nonisolated struct ApplicationDefinitionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// Stable, string-backed identity for a persona tool definition.
public nonisolated struct ToolDefinitionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// Stable, string-backed identity for a workflow definition.
public nonisolated struct WorkflowDefinitionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// Stable, string-backed identity for a step within a workflow definition.
/// Unique within its containing `PersonaWorkflowDefinition`.
public nonisolated struct StepDefinitionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Step kind vocabulary

/// The shared step classes a workflow definition may use. Every step executor in
/// PJE-006 implements exactly one kind; the engine dispatches to the executor by kind.
/// Personas choose from this fixed vocabulary — they do not introduce new kinds.
public nonisolated enum WorkflowStepKind: String, Codable, Sendable, CaseIterable {
    case intake
    case scope
    case selectEvidence
    case reviewEvidence
    case brainstorm
    case form
    case table
    case matrix
    case timeline
    case graph
    case calculation
    case method
    case decision
    case humanApproval
    case workProductBuild
    case effectivenessReview
    case closure
}

// MARK: - Loop policy

/// Explicit cycle policy required on any step that is the origin of an `isReturn`
/// transition. The runtime enforces the pairing; the compiler validates structure only.
public nonisolated enum WorkflowLoopPolicy: String, Codable, Sendable {
    /// Step may transition back to an earlier named step (branch return or scope revisit).
    case returnsToStep
    /// Step may be repeated on the same iteration before advancing.
    case iterates
}

// MARK: - Transition definition

/// One directed edge in the step graph. Non-terminal steps must have at least one
/// transition; terminal steps must have zero (enforced at run time by PJE-004).
public nonisolated struct WorkflowTransitionDefinition: Sendable {
    public let label: String
    public let targetStepID: StepDefinitionID
    /// When `true` this edge is a declared return loop, exempt from cycle detection.
    /// The source step should declare a `loopPolicy` to communicate intent explicitly.
    public let isReturn: Bool
    /// Optional display-condition expression (evaluated by the step executor at run time).
    public let condition: String?

    public nonisolated init(
        label: String,
        targetStepID: StepDefinitionID,
        isReturn: Bool = false,
        condition: String? = nil
    ) {
        self.label        = label
        self.targetStepID = targetStepID
        self.isReturn     = isReturn
        self.condition    = condition
    }
}

// MARK: - Requirement kind

/// Structured categories of prerequisites a step or workflow definition may declare.
/// PJE-005 enforces these at run time; this enum is definition vocabulary only.
public nonisolated enum WorkflowRequirementKind: String, Codable, Sendable, CaseIterable {
    case canonicalObjectLinked
    case evidenceSelected
    case evidenceReviewed
    case humanDecisionRecorded
    case sensitiveScopeSatisfied
    case formFieldCompleted
    case artifactGenerated
    case validationPassed
    case methodResultPresent
}

// MARK: - Step requirement

/// A declared prerequisite that must be satisfied before the step may advance.
/// `isBlocking = true` prevents advancement; `false` raises an attention item.
public nonisolated struct PersonaWorkflowRequirement: Sendable {
    public let id: String
    public let kind: WorkflowRequirementKind
    public let label: String
    public let isBlocking: Bool
    public let detail: String?

    public nonisolated init(
        id: String,
        kind: WorkflowRequirementKind,
        label: String,
        isBlocking: Bool,
        detail: String? = nil
    ) {
        self.id = id; self.kind = kind; self.label = label
        self.isBlocking = isBlocking; self.detail = detail
    }
}

// MARK: - Validation definition

/// A declared check run against step output before advancement.
/// References a registered validator by stable string ID (resolved in PJE-002).
public nonisolated struct PersonaWorkflowValidation: Sendable {
    public let id: String
    /// Stable ID of the validator in the validator registry (PJE-002).
    public let validatorID: String
    public let label: String
    public let isBlocking: Bool
    public let detail: String?

    public nonisolated init(
        id: String,
        validatorID: String,
        label: String,
        isBlocking: Bool,
        detail: String? = nil
    ) {
        self.id = id; self.validatorID = validatorID; self.label = label
        self.isBlocking = isBlocking; self.detail = detail
    }
}

// MARK: - Artifact definition

/// A declared output artifact. For `workProductBuild` steps, at least one artifact
/// must carry a non-nil `workProductTemplateID`; the compiler enforces this invariant.
public nonisolated struct PersonaWorkflowArtifactDefinition: Sendable {
    public let id: String
    public let label: String
    /// Stable work-product template identifier (from the work-product registry, PJE-002).
    /// Non-nil for work-product outputs; nil for attachment or free-form artifacts.
    public let workProductTemplateID: String?
    public let isRequired: Bool
    public let detail: String?

    public nonisolated init(
        id: String,
        label: String,
        workProductTemplateID: String? = nil,
        isRequired: Bool,
        detail: String? = nil
    ) {
        self.id = id; self.label = label
        self.workProductTemplateID = workProductTemplateID
        self.isRequired = isRequired; self.detail = detail
    }
}

// MARK: - Capability requirement

/// A declared capability the engine must resolve before executing this step.
/// Follows the `context.capabilities.resolve(spec)` contract — no model names.
public nonisolated struct WorkflowCapabilityRequirement: Sendable {
    /// Stable spec key for capability resolution (e.g., `"reasoning"`, `"extraction"`).
    public let specKey: String
    /// `true` = engine must fail-closed when capability is absent.
    public let isRequired: Bool
    public let detail: String?

    public nonisolated init(specKey: String, isRequired: Bool, detail: String? = nil) {
        self.specKey = specKey; self.isRequired = isRequired; self.detail = detail
    }
}

// MARK: - Sensitive-scope requirement

/// The `SensitiveUsePurpose`s this step must enforce. At run time, PJE-005/PJE-007
/// verify the active `SensitiveScope` covers each declared purpose.
public nonisolated struct WorkflowSensitiveScopeRequirement: Sendable {
    public let purposes: Set<SensitiveUsePurpose>
    public let detail: String?

    public nonisolated init(purposes: Set<SensitiveUsePurpose>, detail: String? = nil) {
        self.purposes = purposes; self.detail = detail
    }
}

// MARK: - Step definition

/// One immutable step in a workflow definition.
///
/// Compiler invariants (enforced by `WorkflowDefinitionCompiler`):
/// - Exactly one step per workflow has `isEntry = true`.
/// - At least one terminal step is reachable from the entry step.
/// - `decision` steps declare at least one `decisionBranch`.
/// - `humanApproval` steps declare at least one `approverRole`.
/// - `workProductBuild` steps declare at least one artifact with a non-nil
///   `workProductTemplateID`.
/// - `closure` steps with blocking `validations` declare a blocking `validationPassed`
///   requirement, or the compiler raises `closureStepBypassesRequiredValidation`.
public nonisolated struct PersonaWorkflowStepDefinition: Sendable {
    public let id: StepDefinitionID
    public let kind: WorkflowStepKind
    public let label: String
    public let detail: String?
    public let isEntry: Bool
    public let isTerminal: Bool
    public let transitions: [WorkflowTransitionDefinition]
    public let requirements: [PersonaWorkflowRequirement]
    public let validations: [PersonaWorkflowValidation]
    public let artifacts: [PersonaWorkflowArtifactDefinition]
    public let sensitiveScope: WorkflowSensitiveScopeRequirement?
    public let capabilityRequirements: [WorkflowCapabilityRequirement]
    /// Named decision branches for `decision` steps (e.g., `["confirmed", "rejected"]`).
    public let decisionBranches: [String]
    /// Named approver roles for `humanApproval` steps (e.g., `["supervisor"]`).
    public let approverRoles: [String]
    public let loopPolicy: WorkflowLoopPolicy?

    public nonisolated init(
        id: StepDefinitionID,
        kind: WorkflowStepKind,
        label: String,
        detail: String? = nil,
        isEntry: Bool = false,
        isTerminal: Bool = false,
        transitions: [WorkflowTransitionDefinition] = [],
        requirements: [PersonaWorkflowRequirement] = [],
        validations: [PersonaWorkflowValidation] = [],
        artifacts: [PersonaWorkflowArtifactDefinition] = [],
        sensitiveScope: WorkflowSensitiveScopeRequirement? = nil,
        capabilityRequirements: [WorkflowCapabilityRequirement] = [],
        decisionBranches: [String] = [],
        approverRoles: [String] = [],
        loopPolicy: WorkflowLoopPolicy? = nil
    ) {
        self.id = id; self.kind = kind; self.label = label; self.detail = detail
        self.isEntry = isEntry; self.isTerminal = isTerminal
        self.transitions = transitions; self.requirements = requirements
        self.validations = validations; self.artifacts = artifacts
        self.sensitiveScope = sensitiveScope
        self.capabilityRequirements = capabilityRequirements
        self.decisionBranches = decisionBranches; self.approverRoles = approverRoles
        self.loopPolicy = loopPolicy
    }
}

// MARK: - Workflow definition

/// The immutable definition of one workflow.
///
/// `version` increments whenever the definition changes; `schemaVersion` tracks the
/// definition-contract schema version (distinct from the DB migration version).
/// PJE-003 stores a frozen JSON snapshot alongside its SHA-256 hash so that old runs
/// can be reopened and reconstructed exactly, even after the registered definition
/// is superseded.
public nonisolated struct PersonaWorkflowDefinition: Sendable {
    public let id: WorkflowDefinitionID
    public let version: Int
    public let schemaVersion: Int
    public let label: String
    public let detail: String?
    public let steps: [PersonaWorkflowStepDefinition]
    /// Requirements applied to the workflow as a whole (evaluated at the completion gate).
    public let globalRequirements: [PersonaWorkflowRequirement]
    /// Capabilities the engine must resolve before a run may start.
    public let capabilityRequirements: [WorkflowCapabilityRequirement]

    public nonisolated init(
        id: WorkflowDefinitionID,
        version: Int,
        schemaVersion: Int,
        label: String,
        detail: String? = nil,
        steps: [PersonaWorkflowStepDefinition],
        globalRequirements: [PersonaWorkflowRequirement] = [],
        capabilityRequirements: [WorkflowCapabilityRequirement] = []
    ) {
        self.id = id; self.version = version; self.schemaVersion = schemaVersion
        self.label = label; self.detail = detail; self.steps = steps
        self.globalRequirements = globalRequirements
        self.capabilityRequirements = capabilityRequirements
    }
}

// MARK: - Tool definition

/// Immutable definition of one persona tool: a logical container grouping related
/// workflows. Registered in the tool registry (PJE-002).
public nonisolated struct PersonaToolDefinition: Sendable {
    public let id: ToolDefinitionID
    public let version: Int
    public let label: String
    public let detail: String?
    public let supportedWorkflowIDs: [WorkflowDefinitionID]
    public let capabilityRequirements: [WorkflowCapabilityRequirement]

    public nonisolated init(
        id: ToolDefinitionID,
        version: Int,
        label: String,
        detail: String? = nil,
        supportedWorkflowIDs: [WorkflowDefinitionID] = [],
        capabilityRequirements: [WorkflowCapabilityRequirement] = []
    ) {
        self.id = id; self.version = version; self.label = label; self.detail = detail
        self.supportedWorkflowIDs = supportedWorkflowIDs
        self.capabilityRequirements = capabilityRequirements
    }
}

// MARK: - Application definition

/// Immutable top-level container grouping tools and workflows for one persona application.
/// Registered in the application registry (PJE-002).
public nonisolated struct PersonaApplicationDefinition: Sendable {
    public let id: ApplicationDefinitionID
    public let version: Int
    public let label: String
    public let detail: String?
    public let toolIDs: [ToolDefinitionID]
    public let workflowIDs: [WorkflowDefinitionID]

    public nonisolated init(
        id: ApplicationDefinitionID,
        version: Int,
        label: String,
        detail: String? = nil,
        toolIDs: [ToolDefinitionID] = [],
        workflowIDs: [WorkflowDefinitionID] = []
    ) {
        self.id = id; self.version = version; self.label = label; self.detail = detail
        self.toolIDs = toolIDs; self.workflowIDs = workflowIDs
    }
}
