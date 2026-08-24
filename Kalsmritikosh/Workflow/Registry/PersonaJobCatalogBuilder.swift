//
//  PersonaJobCatalogBuilder.swift
//  Kalsmritikosh
//
//  PJE-002 — PersonaJobCatalogBuilder: accumulates eight registries,
//  validates and resolves all dependencies, and freezes into a PersonaJobCatalog.
//
//  Validation order (deterministic, applied per sorted application):
//    1. Registry-local ID/version validity  — enforced at registration time
//    2. Duplicate registration              — enforced at registration time
//    3. Workflow compilation                — enforced at registration time
//    4. Application / tool / workflow refs
//    5. Terminology
//    6. Object schemas
//    7. Work products + composers
//    8. Validators
//    9. Automations
//   10. Capabilities
//
//  Reserved canonical type names that must never be registered as workflowOwned
//  or proposalLayer:
//    Canonical-reference: Claim, EvidenceBlock, SourceVersion, Entity, Event,
//      HistoryItem, Assertion, GenericFact, TemporalClaim
//    Shared-professional-reference: Issue, ProfessionalTask, Deadline,
//      SensitiveScope, WorkProductRun, SourceReliabilityAssessment
//

import Foundation

// MARK: - Reserved type-name sets

private let canonicalProtectedTypeNames: Set<String> = [
    "Claim", "EvidenceBlock", "SourceVersion", "Entity", "Event",
    "HistoryItem", "Assertion", "GenericFact", "TemporalClaim"
]
private let sharedProtectedTypeNames: Set<String> = [
    "Issue", "ProfessionalTask", "Deadline",
    "SensitiveScope", "WorkProductRun", "SourceReliabilityAssessment"
]
private let allProtectedTypeNames: Set<String> =
    canonicalProtectedTypeNames.union(sharedProtectedTypeNames)

// MARK: - PersonaJobCatalogBuilder

/// Accumulates registrations across eight registries, then freezes them into
/// an immutable `PersonaJobCatalog` after full cross-registry validation.
///
/// Registration methods validate only ID/version/duplicate constraints.
/// Cross-registry dependency validation happens entirely in `build()`.
public nonisolated struct PersonaJobCatalogBuilder {

    private var applicationBuilder:  VersionedDefinitionRegistryBuilder<PersonaApplicationDefinition>  = .init()
    private var toolBuilder:         VersionedDefinitionRegistryBuilder<PersonaToolDefinition>         = .init()
    private var workflowBuilder:     WorkflowDefinitionRegistryBuilder                                 = .init()
    private var objectSchemaBuilder: VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition> = .init()
    private var workProductBuilder:  VersionedDefinitionRegistryBuilder<PersonaWorkProductDefinition>  = .init()
    private var validatorBuilder:    VersionedDefinitionRegistryBuilder<PersonaValidatorDefinition>    = .init()
    private var terminologyBuilder:  VersionedDefinitionRegistryBuilder<PersonaTerminologyDefinition>  = .init()
    private var automationBuilder:   VersionedDefinitionRegistryBuilder<PersonaAutomationDefinition>   = .init()
    private var packages: [PersonaApplicationPackageDefinition] = []

    private let composerRegistry: WorkProductComposerRegistry
    private let availableCapabilitySpecKeys: Set<String>

    public nonisolated init(
        composerRegistry: WorkProductComposerRegistry,
        availableCapabilitySpecKeys: Set<String> = []
    ) {
        self.composerRegistry = composerRegistry
        self.availableCapabilitySpecKeys = availableCapabilitySpecKeys
    }

    // MARK: Registration methods

    public mutating func registerApplication(_ def: PersonaApplicationDefinition) throws {
        try applicationBuilder.register(def)
    }
    public mutating func registerTool(_ def: PersonaToolDefinition) throws {
        try toolBuilder.register(def)
    }
    public mutating func registerWorkflow(_ def: PersonaWorkflowDefinition) throws {
        try workflowBuilder.register(def)
    }
    public mutating func registerObjectSchema(_ def: PersonaObjectSchemaDefinition) throws {
        try objectSchemaBuilder.register(def)
    }
    public mutating func registerWorkProduct(_ def: PersonaWorkProductDefinition) throws {
        try workProductBuilder.register(def)
    }
    public mutating func registerValidator(_ def: PersonaValidatorDefinition) throws {
        try validatorBuilder.register(def)
    }
    public mutating func registerTerminology(_ def: PersonaTerminologyDefinition) throws {
        try terminologyBuilder.register(def)
    }
    public mutating func registerAutomation(_ def: PersonaAutomationDefinition) throws {
        try automationBuilder.register(def)
    }
    /// Stores the application package definition for resolution during `build()`.
    public mutating func registerPackage(_ pkg: PersonaApplicationPackageDefinition) {
        packages.append(pkg)
    }

    // MARK: Build

    /// Freezes all registries, validates every package, resolves all dependencies
    /// to exact highest-version keys, and returns an immutable `PersonaJobCatalog`.
    /// Throws on the first validation error. No partial catalog is returned.
    public func build() throws -> PersonaJobCatalog {
        let appReg      = applicationBuilder.freeze()
        let toolReg     = toolBuilder.freeze()
        let wfReg       = workflowBuilder.freeze()
        let schemaReg   = objectSchemaBuilder.freeze()
        let wpReg       = workProductBuilder.freeze()
        let validReg    = validatorBuilder.freeze()
        let termReg     = terminologyBuilder.freeze()
        let automReg    = automationBuilder.freeze()

        // Sort packages for deterministic validation order.
        let sortedPackages = packages.sorted {
            $0.application.id.rawValue < $1.application.id.rawValue
        }

        var resolvedPackages: [ApplicationDefinitionID: ResolvedPersonaApplicationPackage] = [:]

        for pkg in sortedPackages {
            let resolved = try resolveAndValidate(
                pkg,
                appReg: appReg, toolReg: toolReg, wfReg: wfReg,
                schemaReg: schemaReg, wpReg: wpReg, validReg: validReg,
                termReg: termReg, automReg: automReg
            )
            resolvedPackages[pkg.application.id] = resolved
        }

        return PersonaJobCatalog(
            applications: appReg,
            tools: toolReg,
            workflows: wfReg,
            objectSchemas: schemaReg,
            workProducts: wpReg,
            validators: validReg,
            terminologies: termReg,
            automations: automReg,
            resolvedPackages: resolvedPackages
        )
    }

    // MARK: - Private resolution + validation

    private func resolveAndValidate(
        _ pkg: PersonaApplicationPackageDefinition,
        appReg:    VersionedDefinitionRegistry<PersonaApplicationDefinition>,
        toolReg:   VersionedDefinitionRegistry<PersonaToolDefinition>,
        wfReg:     WorkflowDefinitionRegistry,
        schemaReg: VersionedDefinitionRegistry<PersonaObjectSchemaDefinition>,
        wpReg:     VersionedDefinitionRegistry<PersonaWorkProductDefinition>,
        validReg:  VersionedDefinitionRegistry<PersonaValidatorDefinition>,
        termReg:   VersionedDefinitionRegistry<PersonaTerminologyDefinition>,
        automReg:  VersionedDefinitionRegistry<PersonaAutomationDefinition>
    ) throws -> ResolvedPersonaApplicationPackage {

        let app   = pkg.application
        let appID = app.id
        let appKey = RegistryKey(id: appID, version: app.version)

        // ── Step 4a: Application → tools ──────────────────────────────────
        var toolKeys: [RegistryKey<ToolDefinitionID>] = []
        var tools:    [PersonaToolDefinition]          = []
        for toolID in app.toolIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let resolved = toolReg.latest(id: toolID) else {
                throw PersonaRegistryError.missingTool(applicationID: appID, toolID: toolID)
            }
            toolKeys.append(RegistryKey(id: toolID, version: resolved.version))
            tools.append(resolved)
        }

        // ── Step 4b: Application → workflows ──────────────────────────────
        // Collect all workflow IDs declared by the application plus each tool.
        var allWorkflowIDs: [WorkflowDefinitionID] =
            (app.workflowIDs + tools.flatMap { $0.supportedWorkflowIDs })
            .reduce(into: [WorkflowDefinitionID]()) { if !$0.contains($1) { $0.append($1) } }
        allWorkflowIDs.sort { $0.rawValue < $1.rawValue }

        var workflowKeys: [RegistryKey<WorkflowDefinitionID>] = []
        var workflows:    [ValidatedWorkflowDefinition]        = []
        for wfID in allWorkflowIDs {
            guard let resolved = wfReg.latest(id: wfID) else {
                throw PersonaRegistryError.missingWorkflow(ownerID: appID.rawValue, workflowID: wfID)
            }
            workflowKeys.append(RegistryKey(id: wfID, version: resolved.definition.version))
            workflows.append(resolved)
        }

        // ── Step 4c: Tool → workflow cross-check ──────────────────────────
        for tool in tools {
            for wfID in tool.supportedWorkflowIDs {
                guard wfReg.latest(id: wfID) != nil else {
                    throw PersonaRegistryError.missingWorkflow(
                        ownerID: tool.id.rawValue, workflowID: wfID)
                }
            }
        }

        // ── Step 5: Terminology ───────────────────────────────────────────
        let termID = pkg.terminologyID
        guard let term = termReg.latest(id: termID) else {
            throw PersonaRegistryError.missingTerminology(
                applicationID: appID, terminologyID: termID)
        }
        guard term.applicationID == appID else {
            throw PersonaRegistryError.terminologyApplicationMismatch(
                terminologyID: termID,
                expected: appID,
                actual: term.applicationID)
        }
        for (token, label) in term.labels {
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw PersonaRegistryError.blankTerminologyLabel(
                    terminologyID: termID, token: token)
            }
        }
        let terminologyKey = RegistryKey(id: termID, version: term.version)

        // ── Step 6: Object schemas ────────────────────────────────────────
        var objectSchemaKeys: [RegistryKey<ObjectSchemaDefinitionID>] = []
        var objectSchemas:    [PersonaObjectSchemaDefinition]          = []
        for schemaID in pkg.objectSchemaIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let schema = schemaReg.latest(id: schemaID) else {
                throw PersonaRegistryError.missingObjectSchema(
                    applicationID: appID, schemaID: schemaID)
            }
            // Reserved type name enforcement
            if allProtectedTypeNames.contains(schema.representedTypeName) {
                let allowedOwnerships: Set<PersonaObjectSchemaOwnership> =
                    canonicalProtectedTypeNames.contains(schema.representedTypeName)
                    ? [.canonicalReferenceOnly]
                    : [.sharedProfessionalReferenceOnly]
                guard allowedOwnerships.contains(schema.ownership) else {
                    throw PersonaRegistryError.illegalObjectSchemaOwnership(
                        representedTypeName: schema.representedTypeName,
                        ownership: schema.ownership)
                }
            }
            objectSchemaKeys.append(RegistryKey(id: schemaID, version: schema.version))
            objectSchemas.append(schema)
        }

        // ── Step 7: Work products + composers ────────────────────────────
        var workProductKeys: [RegistryKey<WorkProductDefinitionID>] = []
        var workProducts:    [PersonaWorkProductDefinition]          = []
        // Build lookup set for artifact-template resolution below.
        var resolvedWPIDs = Set<WorkProductDefinitionID>()
        for wpID in pkg.workProductIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let wp = wpReg.latest(id: wpID) else {
                // No specific workflow ID for this check — use the app as owner.
                throw PersonaRegistryError.missingWorkProduct(
                    workflowID: WorkflowDefinitionID(rawValue: appID.rawValue),
                    workProductID: wpID)
            }
            for composerID in wp.requiredComposerIDs {
                guard composerRegistry.composer(for: composerID) != nil else {
                    throw PersonaRegistryError.missingComposer(
                        workProductID: wpID, composerID: composerID)
                }
            }
            workProductKeys.append(RegistryKey(id: wpID, version: wp.version))
            workProducts.append(wp)
            resolvedWPIDs.insert(wpID)
        }
        // Verify every workflow artifact with a non-nil workProductTemplateID resolves.
        for validated in workflows {
            let wf = validated.definition
            for step in wf.steps {
                for artifact in step.artifacts {
                    guard let templateID = artifact.workProductTemplateID else { continue }
                    let wpID = WorkProductDefinitionID(rawValue: templateID)
                    guard resolvedWPIDs.contains(wpID) else {
                        throw PersonaRegistryError.missingWorkProduct(
                            workflowID: wf.id, workProductID: wpID)
                    }
                }
            }
        }

        // ── Step 8: Validators ────────────────────────────────────────────
        var validatorKeys: [RegistryKey<ValidatorDefinitionID>] = []
        var validators:    [PersonaValidatorDefinition]          = []
        var resolvedValidatorMap: [ValidatorDefinitionID: PersonaValidatorDefinition] = [:]
        for validID in pkg.validatorIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let v = validReg.latest(id: validID) else {
                // We need a workflowID placeholder — use the package application ID.
                throw PersonaRegistryError.missingValidator(
                    workflowID: WorkflowDefinitionID(rawValue: appID.rawValue),
                    stepID: StepDefinitionID(rawValue: ""),
                    validatorID: validID)
            }
            validatorKeys.append(RegistryKey(id: validID, version: v.version))
            validators.append(v)
            resolvedValidatorMap[validID] = v
        }
        // Cross-check workflow step validations against the package validator set.
        for validated in workflows {
            let wf = validated.definition
            for step in wf.steps {
                for stepValidation in step.validations {
                    let vID = ValidatorDefinitionID(rawValue: stepValidation.validatorID)
                    guard let vDef = resolvedValidatorMap[vID] else {
                        throw PersonaRegistryError.missingValidator(
                            workflowID: wf.id, stepID: step.id, validatorID: vID)
                    }
                    guard vDef.supportedStepKinds.contains(step.kind) else {
                        throw PersonaRegistryError.validatorDoesNotSupportStep(
                            validatorID: vID, stepKind: step.kind)
                    }
                }
            }
        }

        // ── Step 9: Automations ───────────────────────────────────────────
        var automationKeys: [RegistryKey<AutomationDefinitionID>] = []
        var automations:    [PersonaAutomationDefinition]          = []
        for automID in pkg.automationIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let a = automReg.latest(id: automID) else {
                throw PersonaRegistryError.missingAutomation(
                    applicationID: appID, automationID: automID)
            }
            automationKeys.append(RegistryKey(id: automID, version: a.version))
            automations.append(a)
        }

        // ── Step 10: Capabilities ─────────────────────────────────────────
        var allCapReqs: [(ownerID: String, req: WorkflowCapabilityRequirement)] = []
        for tool in tools {
            for req in tool.capabilityRequirements {
                allCapReqs.append((tool.id.rawValue, req))
            }
        }
        for validated in workflows {
            let wf = validated.definition
            for req in wf.capabilityRequirements {
                allCapReqs.append((wf.id.rawValue, req))
            }
            for step in wf.steps {
                for req in step.capabilityRequirements {
                    allCapReqs.append((wf.id.rawValue + "/" + step.id.rawValue, req))
                }
            }
        }
        for (ownerID, req) in allCapReqs where req.isRequired {
            guard availableCapabilitySpecKeys.contains(req.specKey) else {
                throw PersonaRegistryError.missingRequiredCapability(
                    ownerID: ownerID, capability: req.specKey)
            }
        }

        return ResolvedPersonaApplicationPackage(
            applicationKey:   appKey,
            application:      app,
            toolKeys:         toolKeys,
            tools:            tools,
            workflowKeys:     workflowKeys,
            workflows:        workflows,
            terminologyKey:   terminologyKey,
            terminology:      term,
            objectSchemaKeys: objectSchemaKeys,
            objectSchemas:    objectSchemas,
            workProductKeys:  workProductKeys,
            workProducts:     workProducts,
            validatorKeys:    validatorKeys,
            validators:       validators,
            automationKeys:   automationKeys,
            automations:      automations
        )
    }
}
