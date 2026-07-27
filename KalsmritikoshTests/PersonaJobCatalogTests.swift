//
//  PersonaJobCatalogTests.swift
//  KalsmritikoshTests
//
//  PJE-002 — PersonaJobCatalog end-to-end and dependency validation.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-002 — PersonaJobCatalog")
struct PersonaJobCatalogTests {

    // MARK: - Shared fixture builders

    private let appID   = ApplicationDefinitionID(rawValue: "com.test.app")
    private let toolID  = ToolDefinitionID(rawValue: "com.test.tool")
    private let wfID    = WorkflowDefinitionID(rawValue: "com.test.workflow")
    private let termID  = TerminologyDefinitionID(rawValue: "com.test.terminology")
    private let schID   = ObjectSchemaDefinitionID(rawValue: "com.test.schema")
    private let wpID    = WorkProductDefinitionID(rawValue: "com.test.workproduct")
    private let valID   = ValidatorDefinitionID(rawValue: "com.test.validator")
    private let automID = AutomationDefinitionID(rawValue: "com.test.automation")

    private func simpleStep(_ rawID: String, isEntry: Bool = false, isTerminal: Bool = false) -> PersonaWorkflowStepDefinition {
        PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: rawID),
            kind: .form, label: rawID,
            isEntry: isEntry, isTerminal: isTerminal)
    }

    private func simpleWorkflow(
        id: WorkflowDefinitionID? = nil,
        version: Int = 1
    ) -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: id ?? wfID,
            version: version,
            schemaVersion: 1,
            label: "Test Workflow",
            steps: [simpleStep("only", isEntry: true, isTerminal: true)]
        )
    }

    private func makeComposerRegistry() -> WorkProductComposerRegistry {
        WorkProductComposerRegistry()
    }

    /// Builds a complete synthetic catalog with one package containing all eight registries.
    private func makeCompleteCatalog(
        composerRegistry: WorkProductComposerRegistry? = nil,
        availableCapabilities: Set<String> = [],
        modifyBuilder: (inout PersonaJobCatalogBuilder) throws -> Void = { _ in }
    ) throws -> PersonaJobCatalog {
        let cr = composerRegistry ?? makeComposerRegistry()
        var b = PersonaJobCatalogBuilder(
            composerRegistry: cr,
            availableCapabilitySpecKeys: availableCapabilities
        )
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "Test App",
            toolIDs: [toolID], workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerTool(PersonaToolDefinition(
            id: toolID, version: 1, label: "Test Tool",
            supportedWorkflowIDs: [wfID]))
        try b.registerWorkflow(simpleWorkflow())
        try b.registerObjectSchema(PersonaObjectSchemaDefinition(
            id: schID, version: 1, label: "Schema",
            representedTypeName: "IntakeForm", ownership: .workflowOwned))
        try b.registerWorkProduct(PersonaWorkProductDefinition(
            id: wpID, version: 1, label: "WP",
            template: .generalSummary))
        try b.registerValidator(PersonaValidatorDefinition(
            id: valID, version: 1, label: "Validator",
            supportedStepKinds: [.form], producesBlockingResults: true))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID,
            labels: [.claim: "Finding"]))
        try b.registerAutomation(PersonaAutomationDefinition(
            id: automID, version: 1, label: "Auto",
            trigger: .manual, action: .createSuggestion))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app,
            terminologyID: termID,
            objectSchemaIDs: [schID],
            workProductIDs: [wpID],
            validatorIDs: [valID],
            automationIDs: [automID]))
        try modifyBuilder(&b)
        return try b.build()
    }

    // MARK: - Case 1: Complete synthetic package resolves

    @Test("A complete synthetic package resolves through all eight registries")
    func completeSyntheticPackageResolves() throws {
        let catalog = try makeCompleteCatalog()
        let pkg = catalog.resolvedPackage(applicationID: appID)
        #expect(pkg != nil)
        #expect(pkg?.application.id == appID)
        #expect(pkg?.tools.count == 1)
        #expect(pkg?.workflows.count == 1)
        #expect(pkg?.objectSchemas.count == 1)
        #expect(pkg?.workProducts.count == 1)
        #expect(pkg?.validators.count == 1)
        #expect(pkg?.automations.count == 1)
        #expect(pkg?.terminology.id == termID)
    }

    // MARK: - Case 2: Exact resolved version keys are retained

    @Test("Resolved package stores exact (ID, version) keys for all dependencies")
    func exactResolvedVersionKeysRetained() throws {
        let catalog = try makeCompleteCatalog()
        let pkg = try #require(catalog.resolvedPackage(applicationID: appID))
        #expect(pkg.applicationKey == RegistryKey(id: appID, version: 1))
        #expect(pkg.toolKeys.first == RegistryKey(id: toolID, version: 1))
        #expect(pkg.workflowKeys.first == RegistryKey(id: wfID, version: 1))
        #expect(pkg.terminologyKey == RegistryKey(id: termID, version: 1))
    }

    // MARK: - Case 3: Highest version selected deterministically

    @Test("Highest registered version is selected for dependency resolution")
    func highestVersionSelectedDeterministically() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App",
            toolIDs: [toolID], workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerTool(PersonaToolDefinition(
            id: toolID, version: 1, label: "T1", supportedWorkflowIDs: [wfID]))
        try b.registerTool(PersonaToolDefinition(
            id: toolID, version: 2, label: "T2", supportedWorkflowIDs: [wfID]))
        try b.registerWorkflow(simpleWorkflow(version: 1))
        try b.registerWorkflow(simpleWorkflow(version: 2))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        let catalog = try b.build()
        let pkg = try #require(catalog.resolvedPackage(applicationID: appID))
        #expect(pkg.toolKeys.first?.version == 2)
        #expect(pkg.workflowKeys.first?.version == 2)
    }

    // MARK: - Case 4: Missing tool blocks build

    @Test("A missing tool blocks catalog construction with missingTool")
    func missingToolBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App",
            toolIDs: [ToolDefinitionID(rawValue: "com.ghost.tool")],
            workflowIDs: [])
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingTool(
            applicationID: appID,
            toolID: ToolDefinitionID(rawValue: "com.ghost.tool")
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 5: Missing workflow blocks build

    @Test("A missing workflow blocks catalog construction with missingWorkflow")
    func missingWorkflowBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App",
            toolIDs: [], workflowIDs: [WorkflowDefinitionID(rawValue: "com.ghost.wf")])
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingWorkflow(
            ownerID: appID.rawValue,
            workflowID: WorkflowDefinitionID(rawValue: "com.ghost.wf")
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 6: Tool referencing unknown workflow blocks build

    @Test("A tool referencing an unknown workflow blocks build with missingWorkflow")
    func toolReferencingUnknownWorkflowBlocksBuild() throws {
        let ghostWF = WorkflowDefinitionID(rawValue: "com.ghost.tool.wf")
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App",
            toolIDs: [toolID], workflowIDs: [])
        try b.registerApplication(app)
        try b.registerTool(PersonaToolDefinition(
            id: toolID, version: 1, label: "T", supportedWorkflowIDs: [ghostWF]))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingWorkflow(
            ownerID: toolID.rawValue, workflowID: ghostWF
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 7: Missing terminology blocks build

    @Test("A missing terminology pack blocks build with missingTerminology")
    func missingTerminologyBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingTerminology(
            applicationID: appID, terminologyID: termID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 8: Terminology/app mismatch blocks build

    @Test("Terminology targeting a different applicationID blocks build")
    func terminologyAppMismatchBlocksBuild() throws {
        let otherApp = ApplicationDefinitionID(rawValue: "com.other.app")
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: otherApp))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.terminologyApplicationMismatch(
            terminologyID: termID, expected: appID, actual: otherApp
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 9: Missing object schema blocks build

    @Test("A missing object schema blocks build with missingObjectSchema")
    func missingObjectSchemaBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID,
            objectSchemaIDs: [schID]))
        #expect(throws: PersonaRegistryError.missingObjectSchema(
            applicationID: appID, schemaID: schID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 10: Missing work-product descriptor blocks build

    @Test("A missing work-product descriptor blocks build with missingWorkProduct")
    func missingWorkProductBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID, workProductIDs: [wpID]))
        #expect(throws: PersonaRegistryError.missingWorkProduct(
            workflowID: WorkflowDefinitionID(rawValue: appID.rawValue),
            workProductID: wpID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 11: Missing composer blocks build

    @Test("A required composer absent from WorkProductComposerRegistry blocks build")
    func missingComposerBlocksBuild() throws {
        let composerID = WorkProductComposerID("com.ghost.composer")
        var b = PersonaJobCatalogBuilder(composerRegistry: WorkProductComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerWorkProduct(PersonaWorkProductDefinition(
            id: wpID, version: 1, label: "WP",
            template: .generalSummary, requiredComposerIDs: [composerID]))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID, workProductIDs: [wpID]))
        #expect(throws: PersonaRegistryError.missingComposer(
            workProductID: wpID, composerID: composerID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 12: Missing validator blocks build

    @Test("A validator ID referenced in a workflow step but not in the package blocks build")
    func missingValidatorBlocksBuild() throws {
        let ghostValID = ValidatorDefinitionID(rawValue: "com.ghost.validator")
        let wfWithValidator = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [
                PersonaWorkflowStepDefinition(
                    id: StepDefinitionID(rawValue: "s1"),
                    kind: .form, label: "S1",
                    isEntry: true, isTerminal: true,
                    validations: [PersonaWorkflowValidation(
                        id: "v1", validatorID: ghostValID.rawValue,
                        label: "Check", isBlocking: true)])
            ]
        )
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithValidator)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingValidator(
            workflowID: wfID,
            stepID: StepDefinitionID(rawValue: "s1"),
            validatorID: ghostValID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 13: Validator/step-kind mismatch blocks build

    @Test("A validator that does not support the referencing step kind blocks build")
    func validatorStepKindMismatchBlocksBuild() throws {
        // Validator only supports .closure; step is .form
        let wfWithValidator = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [
                PersonaWorkflowStepDefinition(
                    id: StepDefinitionID(rawValue: "s1"),
                    kind: .form, label: "S1",
                    isEntry: true, isTerminal: true,
                    validations: [PersonaWorkflowValidation(
                        id: "v1", validatorID: valID.rawValue,
                        label: "Check", isBlocking: false)])
            ]
        )
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithValidator)
        try b.registerValidator(PersonaValidatorDefinition(
            id: valID, version: 1, label: "V",
            supportedStepKinds: [.closure], producesBlockingResults: false))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID, validatorIDs: [valID]))
        #expect(throws: PersonaRegistryError.validatorDoesNotSupportStep(
            validatorID: valID, stepKind: .form
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 14: Missing automation blocks build

    @Test("A missing automation blocks build with missingAutomation")
    func missingAutomationBlocksBuild() throws {
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "App")
        try b.registerApplication(app)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID, automationIDs: [automID]))
        #expect(throws: PersonaRegistryError.missingAutomation(
            applicationID: appID, automationID: automID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 15: Missing required capability blocks build

    @Test("A required capability absent from availableCapabilitySpecKeys blocks build")
    func missingRequiredCapabilityBlocksBuild() throws {
        let wfWithCap = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [simpleStep("only", isEntry: true, isTerminal: true)],
            capabilityRequirements: [WorkflowCapabilityRequirement(
                specKey: "reasoning", isRequired: true)]
        )
        var b = PersonaJobCatalogBuilder(
            composerRegistry: makeComposerRegistry(),
            availableCapabilitySpecKeys: []  // empty — reasoning not available
        )
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithCap)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        #expect(throws: PersonaRegistryError.missingRequiredCapability(
            ownerID: wfID.rawValue, capability: "reasoning"
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 16: Missing optional capability does not block build

    @Test("An optional capability absent from availableCapabilitySpecKeys is permitted")
    func missingOptionalCapabilityDoesNotBlock() throws {
        let wfWithOptCap = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [simpleStep("only", isEntry: true, isTerminal: true)],
            capabilityRequirements: [WorkflowCapabilityRequirement(
                specKey: "vectorSearch", isRequired: false)]
        )
        var b = PersonaJobCatalogBuilder(
            composerRegistry: makeComposerRegistry(),
            availableCapabilitySpecKeys: []
        )
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithOptCap)
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID))
        let catalog = try b.build()
        #expect(catalog.resolvedPackage(applicationID: appID) != nil)
    }

    // MARK: - Case 17: Workflow artifact resolves to registered work product

    @Test("A workflow artifact with workProductTemplateID resolves to a registered work-product descriptor")
    func workflowArtifactResolvesToRegisteredWorkProduct() throws {
        let artifact = PersonaWorkflowArtifactDefinition(
            id: "a1", label: "Output",
            workProductTemplateID: wpID.rawValue,
            isRequired: true)
        let wfWithArtifact = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [PersonaWorkflowStepDefinition(
                id: StepDefinitionID(rawValue: "s1"),
                kind: .workProductBuild, label: "Build",
                isEntry: true, isTerminal: true,
                artifacts: [artifact])]
        )
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithArtifact)
        try b.registerWorkProduct(PersonaWorkProductDefinition(
            id: wpID, version: 1, label: "WP", template: .generalSummary))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID, workProductIDs: [wpID]))
        let catalog = try b.build()
        let pkg = catalog.resolvedPackage(applicationID: appID)
        #expect(pkg != nil)
        #expect(pkg?.workProducts.first?.id == wpID)
    }

    // MARK: - Case 18: Package cannot use undeclared work product

    @Test("An artifact workProductTemplateID not in the package work-product list blocks build")
    func packageCannotUseUndeclaredWorkProduct() throws {
        let artifact = PersonaWorkflowArtifactDefinition(
            id: "a1", label: "Out",
            workProductTemplateID: wpID.rawValue, isRequired: true)
        let wfWithArtifact = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [PersonaWorkflowStepDefinition(
                id: StepDefinitionID(rawValue: "s1"),
                kind: .workProductBuild, label: "Build",
                isEntry: true, isTerminal: true,
                artifacts: [artifact])]
        )
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithArtifact)
        // Registered in the registry but NOT declared in the package's workProductIDs
        try b.registerWorkProduct(PersonaWorkProductDefinition(
            id: wpID, version: 1, label: "WP", template: .generalSummary))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID,
            workProductIDs: []))  // empty — wpID not declared
        #expect(throws: PersonaRegistryError.missingWorkProduct(
            workflowID: wfID, workProductID: wpID
        )) {
            _ = try b.build()
        }
    }

    // MARK: - Case 19: Package cannot use undeclared validator

    @Test("A validator ID in a workflow step not declared in the package blocks build")
    func packageCannotUseUndeclaredValidator() throws {
        let wfWithValidator = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "WF",
            steps: [PersonaWorkflowStepDefinition(
                id: StepDefinitionID(rawValue: "s1"),
                kind: .form, label: "S1",
                isEntry: true, isTerminal: true,
                validations: [PersonaWorkflowValidation(
                    id: "v1", validatorID: valID.rawValue, label: "V", isBlocking: false)])]
        )
        var b = PersonaJobCatalogBuilder(composerRegistry: makeComposerRegistry())
        let app = PersonaApplicationDefinition(
            id: appID, version: 1, label: "App", workflowIDs: [wfID])
        try b.registerApplication(app)
        try b.registerWorkflow(wfWithValidator)
        try b.registerValidator(PersonaValidatorDefinition(
            id: valID, version: 1, label: "V",
            supportedStepKinds: [.form], producesBlockingResults: false))
        try b.registerTerminology(PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID))
        b.registerPackage(PersonaApplicationPackageDefinition(
            application: app, terminologyID: termID,
            validatorIDs: []))  // valID NOT in package
        #expect(throws: PersonaRegistryError.missingValidator(
            workflowID: wfID,
            stepID: StepDefinitionID(rawValue: "s1"),
            validatorID: valID
        )) {
            _ = try b.build()
        }
    }
}
