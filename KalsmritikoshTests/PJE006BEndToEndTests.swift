//
//  PJE006BEndToEndTests.swift
//  KalsmritikoshTests
//
//  PJE-006B gate — one synthetic workflow proves:
//  select canonical evidence → save → close and recreate actors → reopen exact
//  executor versions → review all required evidence → satisfy evidenceReviewed →
//  build timeline → create proposal graph edge → perform deterministic calculation
//  → close and reopen → verify exact IDs, provenance, hashes and results.
//  Plus: canonical-ledger immutability and the activated .evidenceReviewed
//  requirement path through WorkflowRequirementsEngine. 2 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — End-to-end synthetic workflow", .serialized)
@MainActor
struct PJE006BEndToEndTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_400_000)

    // MARK: - Actor rig (recreatable from the same DB file)

    private struct Rig {
        let db: Database
        let repo: WorkflowRunRepository
        let engine: WorkflowStepExecutionEngine
        let gate: CanonicalWorkflowEvidenceReferenceGate
    }

    /// Builds a complete actor stack over an existing DB file — mirrors an app relaunch.
    private func makeRig(db: Database) throws -> Rig {
        let repo = WorkflowRunRepository(database: db)
        let scopeRepo = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: scopeRepo, scope: nil)

        let builder = WorkflowStepExecutorRegistryBuilder()
        let executors: [any WorkflowStepExecutor] = [
            SelectEvidenceStepExecutor(gate: gate),
            ReviewEvidenceStepExecutor(),
            TimelineStepExecutor(gate: gate),
            GraphStepExecutor(gate: gate),
            CalculationStepExecutor(gate: gate)
        ]
        for executor in executors {
            try builder.register(executor)
            try builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: executor.handledKind,
                executorID: executor.executorID, executorVersion: executor.executorVersion))
        }
        let registry = builder.build()

        let requirementsEngine = WorkflowRequirementsEngine(
            repository: repo,
            requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
        let lifecycle = WorkflowLifecycleEngine(
            repository: repo, requirementsEngine: requirementsEngine)
        let engine = WorkflowStepExecutionEngine(
            registry: registry, lifecycleEngine: lifecycle, repository: repo)
        return Rig(db: db, repo: repo, engine: engine, gate: gate)
    }

    // MARK: - Package: selectEvidence → reviewEvidence → timeline → graph → calculation → closure

    private func makePackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje006b.e2e.app")
        let wfID  = WorkflowDefinitionID(rawValue: "com.pje006b.e2e.wf")
        let ids = (
            select: StepDefinitionID(rawValue: "step.select"),
            review: StepDefinitionID(rawValue: "step.review"),
            timeline: StepDefinitionID(rawValue: "step.timeline"),
            graph: StepDefinitionID(rawValue: "step.graph"),
            calc: StepDefinitionID(rawValue: "step.calc"),
            done: StepDefinitionID(rawValue: "step.done")
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
                    label: "All selected evidence reviewed", isBlocking: true)]),
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
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-006B E2E WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "PJE-006B E2E App")
        let termID = TerminologyDefinitionID(rawValue: "com.pje006b.e2e.term")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app, toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    // MARK: - Canonical seeding

    private func seedWorkspaceEntityGap(_ db: Database) async throws -> (ws: UUID, entities: [UUID], gap: UUID) {
        let ws = UUID()
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(ws), .text("E2E WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        var entities: [UUID] = []
        for _ in 0..<2 {
            let fileID = UUID(), koID = UUID(), entityID = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(fileID), .text("file://e2e-\(fileID)"), .text("txt")])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"),
                  .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);
            """, [.uuid(entityID), .text("person"), .text("P"),
                  .text(entityID.uuidString.lowercased()), .uuid(koID)])
            try await db.exec("""
            INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);
            """, [.uuid(ws), .uuid(entityID), .real(t0.timeIntervalSince1970)])
            entities.append(entityID)
        }
        let gap = UUID()
        try await db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(gap), .text("sequenceHole"), .text("missing filings"), .text("cadence"),
              .real(t0.timeIntervalSince1970)])
        return (ws, entities, gap)
    }

    private func canonicalCounts(_ db: Database) async throws -> [Int] {
        var counts: [Int] = []
        for table in ["entities", "claims", "evidence_blocks", "relationships", "events", "gap_nodes"] {
            let n = Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
            counts.append(n)
        }
        return counts
    }

    private func exec(
        _ rig: Rig, runID: UUID, _ command: some Encodable, at time: Date
    ) async throws -> ReopenedWorkflowRun {
        let json = try WorkflowStepPayloadCodec.encode(command)
        return try await rig.engine.executeCommand(
            runID: runID, commandJSON: json, actor: .system, now: time)
    }

    // MARK: - The gate test

    @Test("Full flow with two actor relaunches: IDs, provenance, hashes, results, immutability")
    func fullFlowWithRelaunches() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pje006b-e2e-\(UUID().uuidString).sqlite")
        let db1 = try await MigrationFixtureBuilder.database(atVersion: 76, at: url)
        let (ws, entityIDs, gapID) = try await seedWorkspaceEntityGap(db1)
        let countsBefore = try await canonicalCounts(db1)

        var rig = try makeRig(db: db1)
        let (pkg, wfID) = try makePackage()
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: "PJE-006B E2E", parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)

        // ── 1. Select canonical evidence: two entities + one gap
        var time = t0.addingTimeInterval(60)
        _ = try await exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entityIDs[0].uuidString, reason: "Primary subject"), at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entityIDs[1].uuidString, reason: "Counterparty"), at: time)
        time.addTimeInterval(10)
        let afterSelect = try await exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .gap, canonicalObjectID: gapID.uuidString, reason: "Missing filings window"), at: time)

        let selectStepRunID = try #require(afterSelect.run.currentStepRunID)
        let selectStepRun = try #require(afterSelect.stepRuns.first { $0.id == selectStepRunID })
        let selectedItems = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: selectStepRun.stateJSON).state.items
        #expect(selectedItems.count == 3)
        #expect(selectedItems.map(\.canonicalObjectID) ==
                [entityIDs[0].uuidString, entityIDs[1].uuidString, gapID.uuidString])

        // ── 2. RELAUNCH #1: close and recreate every actor over the same file
        let db2 = try MigrationFixtureBuilder.reopen(at: url)
        rig = try makeRig(db: db2)
        let reopened1 = try await rig.repo.fetchRun(runID)
        let reopenedSelectRun = try #require(reopened1.stepRuns.first { $0.id == selectStepRunID })
        #expect(reopenedSelectRun.executorID == "com.kalsmritikosh.step.selectEvidence")
        #expect(reopenedSelectRun.executorVersion == "1.0")
        let reopenedItems = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: reopenedSelectRun.stateJSON).state.items
        #expect(reopenedItems == selectedItems, "Selection must survive relaunch byte-exact")

        // ── 3. Complete selection → review step; review ALL selected items
        time.addTimeInterval(10)
        let atReview = try await exec(rig, runID: runID, SelectEvidenceStepCommand.complete, at: time)
        #expect(atReview.stepRuns.contains { $0.stepKind == .reviewEvidence && $0.status == .active })

        // Completing review before reviewing anything must be blocked
        time.addTimeInterval(10)
        let rigAtReview = rig
        let timeAtReview = time
        await #expect(throws: (any Error).self) {
            _ = try await self.exec(rigAtReview, runID: runID,
                                    ReviewEvidenceStepCommand.complete, at: timeAtReview)
        }

        for (index, item) in selectedItems.enumerated() {
            time.addTimeInterval(10)
            let status: WorkflowEvidenceReviewStatus = index == 2 ? .needsFollowUp : .reviewed
            _ = try await exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
                itemID: item.id, status: status, note: "review \(index)"), at: time)
        }

        // ── 4. Complete review — the blocking .evidenceReviewed requirement must pass the gate
        time.addTimeInterval(10)
        let atTimeline = try await exec(rig, runID: runID, ReviewEvidenceStepCommand.complete, at: time)
        #expect(atTimeline.stepRuns.contains { $0.stepKind == .timeline && $0.status == .active })

        // ── 5. Timeline: one dated entry, one explicitly undated entry
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: entityIDs[0].uuidString,
            label: "First appearance", dateISO8601: "2025-03-11T00:00:00Z",
            datePrecision: .day, uncertaintyNote: nil, conflictingDates: []), at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, TimelineStepCommand.addEntry(
            objectKind: .gap, canonicalObjectID: gapID.uuidString,
            label: "Missing filings window", dateISO8601: nil,
            datePrecision: nil, uncertaintyNote: "No date recoverable", conflictingDates: []), at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, TimelineStepCommand.complete, at: time)

        // ── 6. Graph: canonical node + proposal node + user-drawn candidate edge
        time.addTimeInterval(10)
        let afterNode1 = try await exec(rig, runID: runID, GraphStepCommand.addCanonicalNode(
            kind: .entity, canonicalObjectID: entityIDs[0].uuidString), at: time)
        time.addTimeInterval(10)
        let afterNode2 = try await exec(rig, runID: runID, GraphStepCommand.addProposalNode(
            label: "Suspected intermediary"), at: time)
        let graphRunID = try #require(afterNode2.run.currentStepRunID)
        let graphRun = try #require(afterNode2.stepRuns.first { $0.id == graphRunID })
        let nodes = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<GraphStepState>.self, from: graphRun.stateJSON).state.nodes
        _ = afterNode1
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, GraphStepCommand.addEdge(
            sourceNodeID: nodes[0].id, targetNodeID: nodes[1].id,
            relationshipType: "routed_payment_via", direction: .directed,
            provenance: .userDrawn(actorIdentifier: "analyst-e2e")), at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, GraphStepCommand.complete, at: time)

        // ── 7. Calculation: sum with canonical provenance + dateDifference
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, CalculationStepCommand.define(
            operation: .sum,
            inputs: [
                WorkflowCalculationInput(literal: .number(1200), referenceKind: .entity,
                                         referenceID: entityIDs[0].uuidString),
                WorkflowCalculationInput(literal: .number(800))
            ],
            units: "EUR"), at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, CalculationStepCommand.define(
            operation: .dateDifference,
            inputs: [
                WorkflowCalculationInput(literal: .date("2025-03-11T00:00:00Z")),
                WorkflowCalculationInput(literal: .date("2025-04-10T00:00:00Z"))
            ],
            units: nil), at: time)
        time.addTimeInterval(10)
        let completed = try await exec(rig, runID: runID, CalculationStepCommand.complete, at: time)
        #expect(completed.run.status == .completed)

        // ── 8. RELAUNCH #2: recreate actors, reopen, verify everything survived exactly
        let db3 = try MigrationFixtureBuilder.reopen(at: url)
        rig = try makeRig(db: db3)
        let final = try await rig.repo.fetchRun(runID)   // repository verifies hashes on reopen
        #expect(final.run.status == .completed)

        // Every completed step run's stored hash matches an independent recomputation
        // under the unified PJE-006B.1 contract: SHA-256 of the exact stored UTF-8 bytes.
        for stepRun in final.stepRuns where !stepRun.stateJSON.isEmpty && stepRun.stateJSON != "{}" {
            let recomputed = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: stepRun.stateJSON)
            #expect(stepRun.stateSHA256 == recomputed,
                    "Hash mismatch on step \(stepRun.stepDefinitionID.rawValue)")
        }

        // Selection IDs exact
        let finalSelect = try #require(final.stepRuns.first { $0.stepKind == .selectEvidence })
        let finalItems = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: finalSelect.stateJSON).state.items
        #expect(finalItems == selectedItems)

        // Review statuses preserved
        let finalReview = try #require(final.stepRuns.first { $0.stepKind == .reviewEvidence })
        let reviews = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<ReviewEvidenceStepState>.self,
            from: finalReview.stateJSON).state.reviews
        #expect(reviews.count == 3)
        #expect(reviews[selectedItems[2].id.uuidString]?.status == .needsFollowUp)

        // Timeline: exact canonical IDs, precision, explicit undated flag
        let finalTimeline = try #require(final.stepRuns.first { $0.stepKind == .timeline })
        let entries = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<TimelineStepState>.self,
            from: finalTimeline.stateJSON).state.entries
        #expect(entries.count == 2)
        #expect(entries[0].canonicalObjectID == entityIDs[0].uuidString)
        #expect(entries[0].datePrecision == .day)
        #expect(entries[1].isUndated == true)

        // Graph: proposal edge provenance and candidate status preserved
        let finalGraph = try #require(final.stepRuns.first { $0.stepKind == .graph })
        let graphState = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<GraphStepState>.self,
            from: finalGraph.stateJSON).state
        #expect(graphState.nodes.count == 2)
        #expect(graphState.edges.count == 1)
        #expect(graphState.edges[0].provenance == .userDrawn(actorIdentifier: "analyst-e2e"))
        #expect(graphState.edges[0].status == .candidate)

        // Calculation: deterministic results preserved and reproducible
        let finalCalc = try #require(final.stepRuns.first { $0.stepKind == .calculation })
        let calcs = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<CalculationStepState>.self,
            from: finalCalc.stateJSON).state.calculations
        #expect(calcs.count == 2)
        #expect(calcs[0].result == 2000)
        #expect(calcs[0].units == "EUR")
        #expect(calcs[1].result == 30)
        #expect(calcs[1].normalizedParameters["unit"] == "days")
        for calc in calcs {
            let recomputed = try WorkflowCalculationEngine.compute(
                operation: calc.operation, inputs: calc.inputs)
            #expect(recomputed.result == calc.result, "Recompute must be deterministic")
        }

        // Executor identity exact on every non-terminal step run
        for stepRun in final.stepRuns where stepRun.stepKind != .closure {
            #expect(stepRun.executorID == "com.kalsmritikosh.step.\(stepRun.stepKind.rawValue)")
            #expect(stepRun.executorVersion == "1.0")
        }

        // ── 9. Canonical ledger untouched — no Claim/EvidenceBlock/relationship mutation
        let countsAfter = try await canonicalCounts(db3)
        #expect(countsAfter == countsBefore,
                "Workflow execution must not mutate canonical tables")
    }

    // MARK: - Requirements engine integration

    @Test(".evidenceReviewed is no longer deferred: failed before review, satisfied after")
    func evidenceReviewedRequirementActivated() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pje006b-req-\(UUID().uuidString).sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: 76, at: url)
        let (ws, entityIDs, _) = try await seedWorkspaceEntityGap(db)
        let rig = try makeRig(db: db)
        let (pkg, wfID) = try makePackage()
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)

        var time = t0.addingTimeInterval(60)
        _ = try await exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entityIDs[0].uuidString, reason: "subject"), at: time)
        time.addTimeInterval(10)
        let atReview = try await exec(rig, runID: runID, SelectEvidenceStepCommand.complete, at: time)

        // The review step definition with its .evidenceReviewed requirement
        let validated = try #require(atReview.contract.reconstructDefinition())
        let reviewStep = try #require(validated.definition.steps.first { $0.kind == .reviewEvidence })

        let requirementsEngine = WorkflowRequirementsEngine(
            repository: rig.repo,
            requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())

        // BEFORE any review: outcome is .failed (not .skipped — the kind is activated)
        let evalBefore = try await requirementsEngine.evaluate(
            stepDefinition: reviewStep, aggregate: atReview)
        if case .failed(let reqID, _, let isBlocking, _) = evalBefore.requirementOutcomes[0] {
            #expect(reqID == "req.reviewed")
            #expect(isBlocking == true)
        } else {
            Issue.record("Expected .failed before review, got \(evalBefore.requirementOutcomes[0])")
        }

        // Review the single selected item
        let selectRun = try #require(atReview.stepRuns.first { $0.stepKind == .selectEvidence })
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: selectRun.stateJSON).state.items
        time.addTimeInterval(10)
        let afterReview = try await exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
            itemID: items[0].id, status: .reviewed, note: nil), at: time)

        // AFTER reviewing everything: outcome is .satisfied
        let evalAfter = try await requirementsEngine.evaluate(
            stepDefinition: reviewStep, aggregate: afterReview)
        if case .satisfied(let reqID) = evalAfter.requirementOutcomes[0] {
            #expect(reqID == "req.reviewed")
        } else {
            Issue.record("Expected .satisfied after review, got \(evalAfter.requirementOutcomes[0])")
        }
    }
}
