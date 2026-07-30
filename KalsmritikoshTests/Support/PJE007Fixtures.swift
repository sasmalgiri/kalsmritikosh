//
//  PJE007Fixtures.swift
//  KalsmritikoshTests
//
//  PJE-007 — shared behavioural-test rig for the Evidence, Attachment and
//  Provenance Bridge. Builds a full provenance actor stack over a real v77
//  database (recreatable over the same file = app relaunch): repository,
//  sensitive-scope repo, canonical evidence gate, provenance reference
//  validator, the step-execution engine wired WITH the validator (the
//  production contract), and the provenance inspector.
//
//  Canonical seeding uses synthetic sources only. Nothing here copies canonical
//  evidence into workflow tables.
//

import Foundation
@testable import Kalsmritikosh

struct PJE007Rig {
    let db: Database
    let url: URL
    let repo: WorkflowRunRepository
    let scopes: SensitiveScopeRepository
    let gate: CanonicalWorkflowEvidenceReferenceGate
    let validator: WorkflowProvenanceReferenceValidator
    let sourceRelations: SourceRelationsRepository
    let engine: WorkflowStepExecutionEngine
    let inspector: WorkflowProvenanceInspector
}

enum PJE007Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_500_000)

    static func newURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pje007-\(UUID().uuidString).sqlite")
    }

    // MARK: - Rig construction

    static func makeRig(at url: URL, migrate: Bool = true) async throws -> PJE007Rig {
        let db: Database = migrate
            ? try await MigrationFixtureBuilder.database(atVersion: 77, at: url)
            : try MigrationFixtureBuilder.reopen(at: url)
        return assemble(db: db, url: url)
    }

    static func assemble(db: Database, url: URL) -> PJE007Rig {
        let repo = WorkflowRunRepository(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: scopes, scope: nil)
        let validator = WorkflowProvenanceReferenceValidator(gate: gate, database: db)
        let sourceRelations = SourceRelationsRepository(database: db)

        let builder = WorkflowStepExecutorRegistryBuilder()
        let executors: [any WorkflowStepExecutor] = [
            IntakeStepExecutor(),
            SelectEvidenceStepExecutor(gate: gate),
            ReviewEvidenceStepExecutor(),
            TimelineStepExecutor(gate: gate),
            GraphStepExecutor(gate: gate),
            CalculationStepExecutor(gate: gate),
            MethodStepExecutor(gate: gate),
            DecisionStepExecutor(),
            HumanApprovalStepExecutor(),
            ClosureStepExecutor()
        ]
        for e in executors {
            try! builder.register(e)
            try! builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: e.handledKind,
                executorID: e.executorID, executorVersion: e.executorVersion))
        }
        let registry = builder.build()

        let requirements = WorkflowRequirementsEngine(
            repository: repo,
            requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
        let lifecycle = WorkflowLifecycleEngine(
            repository: repo, requirementsEngine: requirements)
        let engine = WorkflowStepExecutionEngine(
            registry: registry, lifecycleEngine: lifecycle, repository: repo,
            provenanceValidator: validator)
        let inspector = WorkflowProvenanceInspector(
            repository: repo, database: db, scopes: scopes)

        return PJE007Rig(
            db: db, url: url, repo: repo, scopes: scopes, gate: gate,
            validator: validator, sourceRelations: sourceRelations,
            engine: engine, inspector: inspector)
    }

    // MARK: - Command execution helper

    @discardableResult
    static func exec(
        _ rig: PJE007Rig, runID: UUID, _ command: some Encodable,
        actor: WorkflowLifecycleActor = .system, at time: Date
    ) async throws -> ReopenedWorkflowRun {
        let json = try WorkflowStepPayloadCodec.encode(command)
        return try await rig.engine.executeCommand(
            runID: runID, commandJSON: json, actor: actor, now: time)
    }

    static func human(_ id: String, role: String? = nil) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: role)
    }

    // MARK: - Canonical seeding (synthetic only)

    static func seedWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("PJE-007 WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    /// file → KO → entity, added to `workspace` membership when supplied.
    @discardableResult
    static func seedEntity(_ db: Database, in workspace: UUID?) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), entityID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://ent-\(fileID)"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);
        """, [.uuid(entityID), .text("person"), .text("E"),
              .text(entityID.uuidString.lowercased()), .uuid(koID)])
        if let workspace = workspace {
            try await db.exec("""
            INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);
            """, [.uuid(workspace), .uuid(entityID), .real(t0.timeIntervalSince1970)])
        }
        return entityID
    }

    @discardableResult
    static func seedGap(_ db: Database) async throws -> UUID {
        let gap = UUID()
        try await db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(gap), .text("sequenceHole"), .text("missing"), .text("cadence"),
              .real(t0.timeIntervalSince1970)])
        return gap
    }

    struct SeededSource {
        let fileID: UUID
        let svID: UUID
        let docID: UUID
        let contentHash: String
        let mediaType: String?
        let byteCount: Int
    }

    /// files (+ size) → source_documents (+ media type) → source_versions,
    /// optionally linked to a workspace via workspace_sources so the evidence
    /// gate permits the source version in that workspace.
    @discardableResult
    static func seedSourceVersion(
        _ db: Database, in workspace: UUID?,
        mediaType: String? = "application/pdf", bytes: Int = 4096,
        hashChar: Character = "a"
    ) async throws -> SeededSource {
        let fileID = UUID(), svID = UUID(), docID = UUID()
        let hash = String(repeating: hashChar, count: 64)
        try await db.exec(
            "INSERT INTO files (id, url, source_type, size_bytes) VALUES (?,?,?,?);",
            [.uuid(fileID), .text("file://att-\(fileID).pdf"), .text("pdf"),
             .integer(Int64(bytes))])
        try await db.exec("""
        INSERT INTO source_documents
            (id, logical_source_id, filename, detected_type, mime_type,
             content_hash, extraction_status, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(docID), .uuid(fileID), .text("att.pdf"), .text("pdf"),
              mediaType.map { SQLValue.text($0) } ?? .null,
              .text(hash), .text("done"), .real(0)])
        try await db.exec("""
        INSERT INTO source_versions
            (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(hash), .real(0), .real(0)])
        if let workspace = workspace {
            try await db.exec("""
            INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);
            """, [.uuid(workspace), .uuid(fileID), .real(t0.timeIntervalSince1970)])
        }
        return SeededSource(
            fileID: fileID, svID: svID, docID: docID,
            contentHash: hash, mediaType: mediaType, byteCount: bytes)
    }

    /// A parent→child edge in source_relations (the attachment lineage authority).
    static func seedSourceRelation(
        _ db: Database, parent: UUID, child: UUID, relation: String
    ) async throws {
        try await db.exec("""
        INSERT INTO source_relations (id, parent_file_id, child_file_id, relation, created_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(parent), .uuid(child), .text(relation),
              .real(t0.timeIntervalSince1970)])
    }

    // MARK: - Direct snapshot crafting (owner / revision integrity tamper tests)

    /// Inserts one provenance snapshot row (JSON + hash via the codec) with an
    /// EXPLICIT owner column and revision column, then marks the owner
    /// snapshotV1. Used to reproduce owner/revision mismatches that cannot be
    /// reached by tampering a hash-protected JSON.
    static func craftSnapshotRow(
        _ db: Database, runID: UUID, ownerColumn: WorkflowProvenanceOwner,
        revisionColumn: Int, snapshot: WorkflowProvenanceSnapshot
    ) async throws {
        let encoded = try WorkflowProvenanceCodec.encode(snapshot)
        let sid = UUID()
        let step: SQLValue = ownerColumn.kind == .stepState ? .uuid(ownerColumn.id) : .null
        let art: SQLValue = ownerColumn.kind == .artifact ? .uuid(ownerColumn.id) : .null
        let dec: SQLValue = ownerColumn.kind == .decision ? .uuid(ownerColumn.id) : .null
        try await db.exec("""
            INSERT INTO workflow_provenance_snapshots
                (id, workflow_run_id, owner_kind, step_run_id, artifact_id, decision_id,
                 workflow_run_revision, producer_id, producer_version,
                 source_state_sha256, snapshot_json, snapshot_sha256, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(sid), .uuid(runID), .text(ownerColumn.kind.rawValue),
                  step, art, dec, .integer(Int64(revisionColumn)),
                  .text(snapshot.producerID), .text(snapshot.producerVersion),
                  snapshot.sourceStateSHA256.map { SQLValue.text($0) } ?? .null,
                  .text(encoded.json), .text(encoded.sha256), .real(0)])
        for (ord, ref) in snapshot.references.enumerated() {
            try await db.exec("""
                INSERT INTO workflow_provenance_references
                    (id, snapshot_id, ordinal, reference_kind, canonical_object_id,
                     role, disposition, source_version_id, locator_json, label, note, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(sid), .integer(Int64(ord)),
                      .text(ref.kind.rawValue), .uuid(ref.canonicalObjectID),
                      .text(ref.role.rawValue), .text(ref.disposition.rawValue),
                      ref.sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                      ref.locatorJSON.map { SQLValue.text($0) } ?? .null,
                      ref.label.map { SQLValue.text($0) } ?? .null,
                      ref.note.map { SQLValue.text($0) } ?? .null, .real(0)])
        }
        let table = ownerColumn.kind == .stepState ? "workflow_step_runs"
            : (ownerColumn.kind == .artifact ? "workflow_artifacts" : "workflow_decisions")
        try await db.exec("UPDATE \(table) SET provenance_semantics='snapshotV1' WHERE id=?;",
                          [.uuid(ownerColumn.id)])
    }

    static func exportAccess(_ workspaceID: UUID, level: SensitivityLevel = .restricted) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspaceID, maximumSensitivity: level,
            permitsPrivilegedMaterial: false, purpose: .export))
    }

    // MARK: - Packages

    private static func package(
        suffix: String, steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje007.app.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje007.wf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-007 WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje007.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "PJE-007 App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    /// selectEvidence (entry) → reviewEvidence → timeline → graph → calculation → closure.
    static func evidencePackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            select: StepDefinitionID(rawValue: "step.select.\(suffix)"),
            review: StepDefinitionID(rawValue: "step.review.\(suffix)"),
            timeline: StepDefinitionID(rawValue: "step.timeline.\(suffix)"),
            graph: StepDefinitionID(rawValue: "step.graph.\(suffix)"),
            calc: StepDefinitionID(rawValue: "step.calc.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.select, kind: .selectEvidence, label: "Select", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.review)]),
            PersonaWorkflowStepDefinition(
                id: ids.review, kind: .reviewEvidence, label: "Review",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.timeline)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.reviewed", kind: .evidenceReviewed,
                    label: "All reviewed", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.timeline, kind: .timeline, label: "Timeline",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.graph)]),
            PersonaWorkflowStepDefinition(
                id: ids.graph, kind: .graph, label: "Graph",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.calc)]),
            PersonaWorkflowStepDefinition(
                id: ids.calc, kind: .calculation, label: "Calculation",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.done)]),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true)
        ]
        return try package(suffix: suffix, steps: steps)
    }

    /// intake (entry, carries a non-work-product attachment artifact def) → closure.
    static let attachmentArtifactDefID = "art.attachment.doc"

    static func attachmentPackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let intakeID = StepDefinitionID(rawValue: "step.intake.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: attachmentArtifactDefID, label: "Attached document",
                workProductTemplateID: nil, isRequired: false)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try package(suffix: suffix, steps: [intake, done])
    }

    /// intake (entry, carries a WORK-PRODUCT artifact def) → closure. Used to
    /// prove the attachment coordinator rejects a work-product artifact def.
    static let workProductArtifactDefID = "art.workproduct.doc"
    static let workProductDefID = "com.pje007.wp.summary"

    static func workProductArtifactPackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje007.wpapp.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje007.wpwf.\(suffix)")
        let intakeID = StepDefinitionID(rawValue: "step.intake.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: workProductArtifactDefID, label: "Work product",
                workProductTemplateID: workProductDefID, isRequired: false)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-007 WP WF", steps: [intake, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje007.wpterm.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let wp = PersonaWorkProductDefinition(
            id: WorkProductDefinitionID(rawValue: workProductDefID),
            version: 1, label: "Summary", template: .generalSummary)
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "WP App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [RegistryKey(id: wp.id, version: wp.version)], workProducts: [wp],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    /// intake (entry) → decision (branches proceed/halt) → closure.
    static func decisionPackage(
        suffix: String
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            intake: StepDefinitionID(rawValue: "step.intake.\(suffix)"),
            decision: StepDefinitionID(rawValue: "step.decision.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.intake, kind: .intake, label: "Intake", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.decision)]),
            PersonaWorkflowStepDefinition(
                id: ids.decision, kind: .decision, label: "Decide",
                transitions: [
                    WorkflowTransitionDefinition(label: "proceed", targetStepID: ids.done),
                    WorkflowTransitionDefinition(label: "halt", targetStepID: ids.done)
                ],
                decisionBranches: ["proceed", "halt"]),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true)
        ]
        return try package(suffix: suffix, steps: steps)
    }
}
