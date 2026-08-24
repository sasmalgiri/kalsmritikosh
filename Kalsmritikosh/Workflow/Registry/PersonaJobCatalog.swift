//
//  PersonaJobCatalog.swift
//  Kalsmritikosh
//
//  PJE-002 — Specialized workflow registry, application package manifest,
//  resolved package, and the immutable PersonaJobCatalog.
//
//  WorkflowDefinitionRegistry stores only ValidatedWorkflowDefinition.
//  Compilation happens once at registration; lookups never recompile.
//

import Foundation

// MARK: - Workflow registry

/// Immutable registry of compiled, validated workflow definitions.
/// Definitions are stored pre-compiled; no recompilation occurs on lookup.
public nonisolated struct WorkflowDefinitionRegistry: Sendable {

    private let _sorted: [ValidatedWorkflowDefinition]
    private let _byKey: [RegistryKey<WorkflowDefinitionID>: ValidatedWorkflowDefinition]
    private let _latestVersion: [WorkflowDefinitionID: Int]

    fileprivate nonisolated init(
        sorted: [ValidatedWorkflowDefinition],
        byKey: [RegistryKey<WorkflowDefinitionID>: ValidatedWorkflowDefinition],
        latestVersion: [WorkflowDefinitionID: Int]
    ) {
        self._sorted = sorted
        self._byKey = byKey
        self._latestVersion = latestVersion
    }

    public func validatedDefinition(
        id: WorkflowDefinitionID,
        version: Int
    ) -> ValidatedWorkflowDefinition? {
        _byKey[RegistryKey(id: id, version: version)]
    }

    public func latest(id: WorkflowDefinitionID) -> ValidatedWorkflowDefinition? {
        guard let v = _latestVersion[id] else { return nil }
        return _byKey[RegistryKey(id: id, version: v)]
    }

    public var all: [ValidatedWorkflowDefinition] { _sorted }

    public var allKeys: [RegistryKey<WorkflowDefinitionID>] {
        _sorted.map { RegistryKey(id: $0.definition.id, version: $0.definition.version) }
    }
}

// MARK: - Workflow registry builder

/// Mutable builder for `WorkflowDefinitionRegistry`.
/// Compiles each `PersonaWorkflowDefinition` once at registration.
public struct WorkflowDefinitionRegistryBuilder {

    private var _byKey: [RegistryKey<WorkflowDefinitionID>: ValidatedWorkflowDefinition] = [:]
    private let _compiler = WorkflowDefinitionCompiler()

    public nonisolated init() {}

    /// Validates the ID and version, rejects duplicates, compiles the definition,
    /// and stores the resulting `ValidatedWorkflowDefinition`.
    public mutating func register(_ definition: PersonaWorkflowDefinition) throws {
        let raw = definition.id.rawValue
        guard !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespaces),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw PersonaRegistryError.invalidID(raw) }
        guard definition.version >= 1 else {
            throw PersonaRegistryError.invalidVersion(id: raw, version: definition.version)
        }
        let key = RegistryKey(id: definition.id, version: definition.version)
        guard _byKey[key] == nil else {
            throw PersonaRegistryError.duplicateRegistration(
                registry: "WorkflowDefinitionRegistry",
                id: raw,
                version: definition.version
            )
        }
        do {
            let validated = try _compiler.compile(definition)
            _byKey[key] = validated
        } catch let compilationError as WorkflowDefinitionError {
            throw PersonaRegistryError.workflowCompilationFailed(
                id: definition.id,
                version: definition.version,
                error: compilationError
            )
        }
    }

    public func freeze() -> WorkflowDefinitionRegistry {
        let sorted = _byKey.values.sorted {
            if $0.definition.id.rawValue != $1.definition.id.rawValue {
                return $0.definition.id.rawValue < $1.definition.id.rawValue
            }
            return $0.definition.version < $1.definition.version
        }
        var latestVersion: [WorkflowDefinitionID: Int] = [:]
        for v in _byKey.values {
            let vid = v.definition.id
            latestVersion[vid] = max(latestVersion[vid, default: 0], v.definition.version)
        }
        return WorkflowDefinitionRegistry(sorted: sorted, byKey: _byKey, latestVersion: latestVersion)
    }
}

// MARK: - Application package manifest

/// Declares the full dependency set for one persona application package.
/// Raw IDs (no versions) are resolved to the highest registered version at catalog-freeze time.
public nonisolated struct PersonaApplicationPackageDefinition: Sendable {
    public let application: PersonaApplicationDefinition
    public let terminologyID: TerminologyDefinitionID
    public let objectSchemaIDs: [ObjectSchemaDefinitionID]
    public let workProductIDs: [WorkProductDefinitionID]
    public let validatorIDs: [ValidatorDefinitionID]
    public let automationIDs: [AutomationDefinitionID]

    public nonisolated init(
        application: PersonaApplicationDefinition,
        terminologyID: TerminologyDefinitionID,
        objectSchemaIDs: [ObjectSchemaDefinitionID] = [],
        workProductIDs: [WorkProductDefinitionID] = [],
        validatorIDs: [ValidatorDefinitionID] = [],
        automationIDs: [AutomationDefinitionID] = []
    ) {
        self.application = application
        self.terminologyID = terminologyID
        self.objectSchemaIDs = objectSchemaIDs
        self.workProductIDs = workProductIDs
        self.validatorIDs = validatorIDs
        self.automationIDs = automationIDs
    }
}

// MARK: - Resolved application package

/// Version-pinned snapshot of all resolved dependencies for one persona application.
/// This exact package is the input to PJE-003 run persistence.
public nonisolated struct ResolvedPersonaApplicationPackage: Sendable {
    public let applicationKey: RegistryKey<ApplicationDefinitionID>
    public let application: PersonaApplicationDefinition

    public let toolKeys: [RegistryKey<ToolDefinitionID>]
    public let tools: [PersonaToolDefinition]

    public let workflowKeys: [RegistryKey<WorkflowDefinitionID>]
    public let workflows: [ValidatedWorkflowDefinition]

    public let terminologyKey: RegistryKey<TerminologyDefinitionID>
    public let terminology: PersonaTerminologyDefinition

    public let objectSchemaKeys: [RegistryKey<ObjectSchemaDefinitionID>]
    public let objectSchemas: [PersonaObjectSchemaDefinition]

    public let workProductKeys: [RegistryKey<WorkProductDefinitionID>]
    public let workProducts: [PersonaWorkProductDefinition]

    public let validatorKeys: [RegistryKey<ValidatorDefinitionID>]
    public let validators: [PersonaValidatorDefinition]

    public let automationKeys: [RegistryKey<AutomationDefinitionID>]
    public let automations: [PersonaAutomationDefinition]

    public nonisolated init(
        applicationKey: RegistryKey<ApplicationDefinitionID>,
        application: PersonaApplicationDefinition,
        toolKeys: [RegistryKey<ToolDefinitionID>],
        tools: [PersonaToolDefinition],
        workflowKeys: [RegistryKey<WorkflowDefinitionID>],
        workflows: [ValidatedWorkflowDefinition],
        terminologyKey: RegistryKey<TerminologyDefinitionID>,
        terminology: PersonaTerminologyDefinition,
        objectSchemaKeys: [RegistryKey<ObjectSchemaDefinitionID>],
        objectSchemas: [PersonaObjectSchemaDefinition],
        workProductKeys: [RegistryKey<WorkProductDefinitionID>],
        workProducts: [PersonaWorkProductDefinition],
        validatorKeys: [RegistryKey<ValidatorDefinitionID>],
        validators: [PersonaValidatorDefinition],
        automationKeys: [RegistryKey<AutomationDefinitionID>],
        automations: [PersonaAutomationDefinition]
    ) {
        self.applicationKey = applicationKey; self.application = application
        self.toolKeys = toolKeys; self.tools = tools
        self.workflowKeys = workflowKeys; self.workflows = workflows
        self.terminologyKey = terminologyKey; self.terminology = terminology
        self.objectSchemaKeys = objectSchemaKeys; self.objectSchemas = objectSchemas
        self.workProductKeys = workProductKeys; self.workProducts = workProducts
        self.validatorKeys = validatorKeys; self.validators = validators
        self.automationKeys = automationKeys; self.automations = automations
    }
}

// MARK: - PersonaJobCatalog

/// Immutable, frozen catalog containing eight registries and resolved application packages.
/// No registration API. No mutable dictionary escapes.
/// All reads are deterministic.
public struct PersonaJobCatalog: Sendable {

    private let _applications: VersionedDefinitionRegistry<PersonaApplicationDefinition>
    private let _tools: VersionedDefinitionRegistry<PersonaToolDefinition>
    private let _workflows: WorkflowDefinitionRegistry
    private let _objectSchemas: VersionedDefinitionRegistry<PersonaObjectSchemaDefinition>
    private let _workProducts: VersionedDefinitionRegistry<PersonaWorkProductDefinition>
    private let _validators: VersionedDefinitionRegistry<PersonaValidatorDefinition>
    private let _terminologies: VersionedDefinitionRegistry<PersonaTerminologyDefinition>
    private let _automations: VersionedDefinitionRegistry<PersonaAutomationDefinition>
    private let _resolvedPackages: [ApplicationDefinitionID: ResolvedPersonaApplicationPackage]

    internal nonisolated init(
        applications: VersionedDefinitionRegistry<PersonaApplicationDefinition>,
        tools: VersionedDefinitionRegistry<PersonaToolDefinition>,
        workflows: WorkflowDefinitionRegistry,
        objectSchemas: VersionedDefinitionRegistry<PersonaObjectSchemaDefinition>,
        workProducts: VersionedDefinitionRegistry<PersonaWorkProductDefinition>,
        validators: VersionedDefinitionRegistry<PersonaValidatorDefinition>,
        terminologies: VersionedDefinitionRegistry<PersonaTerminologyDefinition>,
        automations: VersionedDefinitionRegistry<PersonaAutomationDefinition>,
        resolvedPackages: [ApplicationDefinitionID: ResolvedPersonaApplicationPackage]
    ) {
        self._applications = applications; self._tools = tools
        self._workflows = workflows; self._objectSchemas = objectSchemas
        self._workProducts = workProducts; self._validators = validators
        self._terminologies = terminologies; self._automations = automations
        self._resolvedPackages = resolvedPackages
    }

    // MARK: Application reads

    public func application(id: ApplicationDefinitionID, version: Int) -> PersonaApplicationDefinition? {
        _applications.definition(id: id, version: version)
    }
    public func latestApplication(id: ApplicationDefinitionID) -> PersonaApplicationDefinition? {
        _applications.latest(id: id)
    }
    public var allApplications: [PersonaApplicationDefinition] { _applications.all }

    // MARK: Tool reads

    public func tool(id: ToolDefinitionID, version: Int) -> PersonaToolDefinition? {
        _tools.definition(id: id, version: version)
    }
    public func latestTool(id: ToolDefinitionID) -> PersonaToolDefinition? {
        _tools.latest(id: id)
    }
    public var allTools: [PersonaToolDefinition] { _tools.all }

    // MARK: Workflow reads

    public func workflow(id: WorkflowDefinitionID, version: Int) -> ValidatedWorkflowDefinition? {
        _workflows.validatedDefinition(id: id, version: version)
    }
    public func latestWorkflow(id: WorkflowDefinitionID) -> ValidatedWorkflowDefinition? {
        _workflows.latest(id: id)
    }
    public var allWorkflows: [ValidatedWorkflowDefinition] { _workflows.all }

    // MARK: Object schema reads

    public func objectSchema(id: ObjectSchemaDefinitionID, version: Int) -> PersonaObjectSchemaDefinition? {
        _objectSchemas.definition(id: id, version: version)
    }
    public func latestObjectSchema(id: ObjectSchemaDefinitionID) -> PersonaObjectSchemaDefinition? {
        _objectSchemas.latest(id: id)
    }
    public var allObjectSchemas: [PersonaObjectSchemaDefinition] { _objectSchemas.all }

    // MARK: Work product reads

    public func workProduct(id: WorkProductDefinitionID, version: Int) -> PersonaWorkProductDefinition? {
        _workProducts.definition(id: id, version: version)
    }
    public func latestWorkProduct(id: WorkProductDefinitionID) -> PersonaWorkProductDefinition? {
        _workProducts.latest(id: id)
    }
    public var allWorkProducts: [PersonaWorkProductDefinition] { _workProducts.all }

    // MARK: Validator reads

    public func validator(id: ValidatorDefinitionID, version: Int) -> PersonaValidatorDefinition? {
        _validators.definition(id: id, version: version)
    }
    public func latestValidator(id: ValidatorDefinitionID) -> PersonaValidatorDefinition? {
        _validators.latest(id: id)
    }
    public var allValidators: [PersonaValidatorDefinition] { _validators.all }

    // MARK: Terminology reads

    public func terminology(id: TerminologyDefinitionID, version: Int) -> PersonaTerminologyDefinition? {
        _terminologies.definition(id: id, version: version)
    }
    public func latestTerminology(id: TerminologyDefinitionID) -> PersonaTerminologyDefinition? {
        _terminologies.latest(id: id)
    }
    public var allTerminologies: [PersonaTerminologyDefinition] { _terminologies.all }

    // MARK: Automation reads

    public func automation(id: AutomationDefinitionID, version: Int) -> PersonaAutomationDefinition? {
        _automations.definition(id: id, version: version)
    }
    public func latestAutomation(id: AutomationDefinitionID) -> PersonaAutomationDefinition? {
        _automations.latest(id: id)
    }
    public var allAutomations: [PersonaAutomationDefinition] { _automations.all }

    // MARK: Resolved package reads

    public func resolvedPackage(
        applicationID: ApplicationDefinitionID
    ) -> ResolvedPersonaApplicationPackage? {
        _resolvedPackages[applicationID]
    }

    public var allResolvedPackages: [ResolvedPersonaApplicationPackage] {
        _resolvedPackages.values.sorted { $0.application.id.rawValue < $1.application.id.rawValue }
    }
}
