//
//  PJE006CFixtures.swift
//  KalsmritikoshTests
//
//  PJE-006C — shared DB-backed rig: full executor registry (all 17 kinds),
//  assembly service, build coordinator, engines, and canonical seeding for a
//  composable workspace (file → KO → source version → evidence block → fact →
//  backfilled Claim).
//

import Foundation
@testable import Kalsmritikosh

struct PJE006CRig {
    let db: Database
    let dbURL: URL
    let repo: WorkflowRunRepository
    let workspaces: WorkspaceRepository
    let scopes: SensitiveScopeRepository
    let genericFacts: GenericFactRepository
    let producer: ClaimProducer
    let assembly: WorkProductAssemblyService
    let coordinator: WorkflowWorkProductBuildCoordinator
    let engine: WorkflowStepExecutionEngine
}

enum PJE006CFixtures {

    static let wpDefID = "com.pje006c.wp.summary"
    static let artifactDefID = "artifact.summary"

    // MARK: - Rig construction (recreatable over the same DB file = app relaunch)

    static func newDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pje006c-\(UUID().uuidString).sqlite")
    }

    @MainActor
    static func makeRig(at url: URL, migrate: Bool = true) async throws -> PJE006CRig {
        let db = try Database(url: url)
        if migrate { try await SchemaMigrations.migrate(db) }
        return try await assemble(db: db, url: url)
    }

    @MainActor
    private static func assemble(db: Database, url: URL) async throws -> PJE006CRig {
        let workspaces = WorkspaceRepository(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let producer = ClaimProducer(
            genericFacts: gf,
            assertions: AssertionsRepository(database: db),
            temporalClaims: TemporalClaimRepository(database: db),
            events: EventsRepository(database: db),
            claims: ClaimRepository(database: db),
            evidence: EvidenceStore(database: db))
        let assembly = try WorkProductAssemblyService(
            database: db,
            events: EventsRepository(database: db),
            contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db),
            workspaces: workspaces)
        let repo = WorkflowRunRepository(database: db)
        let coordinator = WorkflowWorkProductBuildCoordinator(
            assembly: assembly, workflowRuns: repo, workspaces: workspaces)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: scopes, scope: nil)
        let registry = try makeFullRegistry(gate: gate)
        let requirements = WorkflowRequirementsEngine(
            repository: repo, workspaces: workspaces,
            requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
        let lifecycle = WorkflowLifecycleEngine(
            repository: repo, requirementsEngine: requirements)
        // PJE-007: executor references are revalidated through the gate before
        // persistence — the rig wires the validator the production engine requires.
        let validator = WorkflowProvenanceReferenceValidator(gate: gate, database: db)
        let engine = WorkflowStepExecutionEngine(
            registry: registry, lifecycleEngine: lifecycle, repository: repo,
            workProductCoordinator: coordinator,
            provenanceValidator: validator)
        return PJE006CRig(
            db: db, dbURL: url, repo: repo, workspaces: workspaces, scopes: scopes,
            genericFacts: gf, producer: producer, assembly: assembly,
            coordinator: coordinator, engine: engine)
    }

    /// Registry with executable Stage 3 coverage for ALL 17 shared step kinds.
    static func makeFullRegistry(
        gate: any WorkflowEvidenceReferenceGating
    ) throws -> WorkflowStepExecutorRegistry {
        let executors: [any WorkflowStepExecutor] = [
            IntakeStepExecutor(),
            ScopeStepExecutor(),
            SelectEvidenceStepExecutor(gate: gate),
            ReviewEvidenceStepExecutor(),
            BrainstormStepExecutor(),
            FormStepExecutor(),
            TableStepExecutor(),
            MatrixStepExecutor(),
            TimelineStepExecutor(gate: gate),
            GraphStepExecutor(gate: gate),
            CalculationStepExecutor(gate: gate),
            MethodStepExecutor(gate: gate),
            DecisionStepExecutor(),
            HumanApprovalStepExecutor(),
            WorkProductBuildStepExecutor(),
            EffectivenessReviewStepExecutor(gate: gate),
            ClosureStepExecutor()
        ]
        let builder = WorkflowStepExecutorRegistryBuilder()
        for executor in executors {
            try builder.register(executor)
            try builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: executor.handledKind,
                executorID: executor.executorID, executorVersion: executor.executorVersion))
        }
        return builder.build()
    }

    // MARK: - Canonical seeding (from the accepted OPS-003C pattern)

    /// file → KO → source_version → evidence_block → evidence_block_object → GenericFact.
    @discardableResult
    @MainActor
    static func seedFact(_ rig: PJE006CRig, value: String) async throws -> (fileID: UUID, koID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await rig.db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await rig.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await rig.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(svID), .uuid(fileID), .uuid(docID),
              .text(String(repeating: "b", count: 64)), .real(0), .real(0)])
        try await rig.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind,
            raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"),
              .text(value), .text(value), .text("native"), .real(1.0)])
        try await rig.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at)
        VALUES (?,?,?);
        """, [.uuid(blockID), .uuid(koID), .real(0)])
        try await rig.genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Doc", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [blockID]))
        return (fileID, koID)
    }

    /// Workspace with `fileID` as its sole source + derived membership + backfilled Claims.
    @MainActor
    static func makeComposableWorkspace(
        _ rig: PJE006CRig, fileID: UUID, at t0: Date
    ) async throws -> Workspace {
        let wsID = UUID()
        let ws = Workspace(id: wsID, title: "PJE-006C WS", template: .general)
        try await rig.workspaces.upsert(ws)
        try await rig.workspaces.addSource(fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: rig.db, workspaces: rig.workspaces)
            .deriveMembership(for: wsID)
        _ = try await rig.producer.backfill(at: t0)
        return ws
    }

    static func exportAccess(workspaceID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspaceID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
    }

    // MARK: - Packages

    /// A single-step build workflow: workProductBuild (entry) → done.
    static func makeBuildOnlyPackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let buildID = StepDefinitionID(rawValue: "step.build.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let build = PersonaWorkflowStepDefinition(
            id: buildID, kind: .workProductBuild, label: "Build", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            requirements: [PersonaWorkflowRequirement(
                id: "req.artifact", kind: .artifactGenerated,
                label: "Report generated", isBlocking: true)],
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: artifactDefID, label: "Summary report",
                workProductTemplateID: wpDefID, isRequired: true)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try package(
            suffix: suffix, steps: [build, done],
            workProducts: [summaryWorkProduct()])
    }

    /// The full Stage 3 gate workflow:
    /// method → decision → workProductBuild → effectivenessReview → humanApproval → closure → done.
    static func makeStage3Package(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            method: StepDefinitionID(rawValue: "step.method.\(suffix)"),
            decision: StepDefinitionID(rawValue: "step.decision.\(suffix)"),
            build: StepDefinitionID(rawValue: "step.build.\(suffix)"),
            review: StepDefinitionID(rawValue: "step.review.\(suffix)"),
            approval: StepDefinitionID(rawValue: "step.approval.\(suffix)"),
            closure: StepDefinitionID(rawValue: "step.closure.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.method, kind: .method, label: "Method", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.decision)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.method-result", kind: .methodResultPresent,
                    label: "Method result attached", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.decision, kind: .decision, label: "Decide",
                transitions: [
                    WorkflowTransitionDefinition(label: "proceed", targetStepID: ids.build),
                    WorkflowTransitionDefinition(label: "halt", targetStepID: ids.done)
                ],
                decisionBranches: ["proceed", "halt"]),
            PersonaWorkflowStepDefinition(
                id: ids.build, kind: .workProductBuild, label: "Build",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.review)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.artifact", kind: .artifactGenerated,
                    label: "Report generated", isBlocking: true)],
                artifacts: [PersonaWorkflowArtifactDefinition(
                    id: artifactDefID, label: "Summary report",
                    workProductTemplateID: wpDefID, isRequired: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.review, kind: .effectivenessReview, label: "Review",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.approval)]),
            PersonaWorkflowStepDefinition(
                id: ids.approval, kind: .humanApproval, label: "Approve",
                transitions: [
                    WorkflowTransitionDefinition(label: "approved", targetStepID: ids.closure),
                    WorkflowTransitionDefinition(label: "rejected", targetStepID: ids.done)
                ],
                approverRoles: ["supervisor"]),
            PersonaWorkflowStepDefinition(
                id: ids.closure, kind: .closure, label: "Close",
                transitions: [WorkflowTransitionDefinition(label: "finish", targetStepID: ids.done)]),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true)
        ]
        return try package(
            suffix: suffix, steps: steps,
            workProducts: [summaryWorkProduct()])
    }

    private static func summaryWorkProduct() -> PersonaWorkProductDefinition {
        PersonaWorkProductDefinition(
            id: WorkProductDefinitionID(rawValue: wpDefID),
            version: 1, label: "General summary", template: .generalSummary)
    }

    private static func package(
        suffix: String,
        steps: [PersonaWorkflowStepDefinition],
        workProducts: [PersonaWorkProductDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje006c.app.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje006c.wf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-006C WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje006c.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "PJE-006C App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: workProducts.map { RegistryKey(id: $0.id, version: $0.version) },
            workProducts: workProducts,
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }
}
