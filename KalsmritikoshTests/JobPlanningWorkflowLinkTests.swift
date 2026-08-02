//
//  JobPlanningWorkflowLinkTests.swift
//  KalsmritikoshTests
//
//  TBJ-FINAL — workflow linkage. A Job may reference a WorkflowRun / step / requirement / evidence
//  requirement / expected artifact, and the planner resolves each against the LIVE workflow authority
//  (never a fork). Covers the pure status→state mappings for every closed-set case, plus a real run
//  created through WorkflowRunRepository, and honest `unresolved` when a referenced run is gone.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TBJ-FINAL — workflow linkage", .serialized)
struct JobPlanningWorkflowLinkTests {

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Pure status mappings (every closed-set case)

    @Test("Every workflow run status maps to a deterministic reference state")
    func runStateMapping() {
        #expect(JobPlanningService.runState(.draft) == .notStarted)
        #expect(JobPlanningService.runState(.active) == .inProgress)
        #expect(JobPlanningService.runState(.paused) == .inProgress)
        #expect(JobPlanningService.runState(.waitingForHuman) == .waitingReview)
        #expect(JobPlanningService.runState(.blocked) == .blocked)
        #expect(JobPlanningService.runState(.completed) == .complete)
        #expect(JobPlanningService.runState(.cancelled) == .unresolved)
        #expect(JobPlanningService.runState(.superseded) == .unresolved)
    }

    @Test("Every workflow step status maps to a deterministic reference state")
    func stepStateMapping() {
        #expect(JobPlanningService.stepState(.ready) == .notStarted)
        #expect(JobPlanningService.stepState(.active) == .inProgress)
        #expect(JobPlanningService.stepState(.waiting) == .waitingReview)
        #expect(JobPlanningService.stepState(.blocked) == .blocked)
        #expect(JobPlanningService.stepState(.completed) == .complete)
        #expect(JobPlanningService.stepState(.skipped) == .complete)
        #expect(JobPlanningService.stepState(.cancelled) == .unresolved)
        #expect(JobPlanningService.stepState(.superseded) == .unresolved)
    }

    // MARK: - Real run integration

    private struct Rig {
        let db: Database
        let jobs: JobRepository
        let workflows: WorkflowRunRepository
        let service: JobPlanningService
        let ws: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS"), .text("general"),
                           .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let tasks = ProfessionalTaskRepository(database: db)
        let deadlines = DeadlineRepository(database: db)
        let workflows = WorkflowRunRepository(database: db)
        return Rig(db: db, jobs: JobRepository(database: db), workflows: workflows,
                   service: JobPlanningService(tasks: tasks, deadlines: deadlines, workflows: workflows), ws: ws)
    }

    private func makeMinimalPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.tbj.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.tbj.test.workflow")
        let termID = TerminologyDefinitionID(rawValue: "com.tbj.test.term")
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "TBJ Test App")
        let entryStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.intake"), kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))])
        let doneStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.done"), kind: .closure, label: "Done", isTerminal: true)
        let wfDef = PersonaWorkflowDefinition(id: wfID, version: 1, schemaVersion: 1, label: "TBJ Test Workflow",
                                              steps: [entryStep, doneStep])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1), application: app,
            toolKeys: [], tools: [], workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [], workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [], automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    @Test("A job reference to a real draft run resolves to notStarted through the workflow authority")
    func draftRunResolves() async throws {
        let r = try await rig()
        let (pkg, wfID) = try makeMinimalPackage()
        let run = try await r.workflows.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: r.ws,
                                                  title: "Run", parentRunID: nil, actorKind: .system,
                                                  actorIdentifier: nil, now: t0)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil, budget: .none,
                                             primaryWorkflowRunID: run.run.id, actor: "u", at: t0)
        let withRef = try await r.jobs.addReference(jobID: rec.objective.id, kind: .workflowRun,
                                                    referenceID: run.run.id.uuidString, workflowRunID: nil,
                                                    role: .required, isMinimumDeliverable: true, note: nil,
                                                    expectedRevision: 1, actor: "u", at: t0)
        let states = try await r.service.resolveStates(withRef.references)
        #expect(states.first?.state == .notStarted)       // draft
    }

    @Test("An evidence requirement on an unfinished run reads as missing; an absent artifact as not started")
    func requirementAndArtifactOnUnfinishedRun() async throws {
        let r = try await rig()
        let (pkg, wfID) = try makeMinimalPackage()
        let run = try await r.workflows.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: r.ws,
                                                  title: "Run", parentRunID: nil, actorKind: .system,
                                                  actorIdentifier: nil, now: t0)
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil, budget: .none,
                                             primaryWorkflowRunID: run.run.id, actor: "u", at: t0)
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .evidenceRequirement,
                                            referenceID: "decisive-evidence", workflowRunID: run.run.id,
                                            role: .required, isMinimumDeliverable: false, note: nil,
                                            expectedRevision: 1, actor: "u", at: t0)
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .expectedArtifact,
                                            referenceID: "final-report", workflowRunID: run.run.id,
                                            role: .required, isMinimumDeliverable: false, note: nil,
                                            expectedRevision: rec.objective.revision, actor: "u", at: t0)
        let states = try await r.service.resolveStates(rec.references)
        #expect(states.first { $0.reference.kind == .evidenceRequirement }?.state == .missingEvidence)
        #expect(states.first { $0.reference.kind == .expectedArtifact }?.state == .notStarted)
    }

    @Test("A reference to a run that no longer exists resolves honestly as unresolved, not complete")
    func missingRunIsUnresolved() async throws {
        let r = try await rig()
        // A run id that was never created — reference validation is skipped for definition-level kinds,
        // but a workflowRun reference must resolve; add it directly at the DB layer to simulate a run
        // deleted after the reference was recorded, then resolve.
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        let ghostRun = UUID()
        try await r.db.exec("""
            INSERT INTO job_plan_references (id, job_id, reference_kind, reference_id, workflow_run_id,
                role, is_minimum_deliverable, ordinal, note, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(rec.objective.id), .text("workflowRun"), .text(ghostRun.uuidString),
                  .null, .text("required"), .integer(0), .integer(0), .null, .real(t0.timeIntervalSince1970)])
        let refs = try await r.jobs.references(jobID: rec.objective.id)
        let states = try await r.service.resolveStates(refs)
        #expect(states.first?.state == .unresolved)
    }

    @Test("A workflow-run reference from another workspace is refused at bind time")
    func crossWorkspaceRunRefused() async throws {
        let r = try await rig()
        let otherWS = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                            [.uuid(otherWS), .text("B"), .text("general"),
                             .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let (pkg, wfID) = try makeMinimalPackage()
        let foreignRun = try await r.workflows.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: otherWS,
                                                         title: "Run", parentRunID: nil, actorKind: .system,
                                                         actorIdentifier: nil, now: t0)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .workflowRun,
                                              referenceID: foreignRun.run.id.uuidString, workflowRunID: nil,
                                              role: .required, isMinimumDeliverable: false, note: nil,
                                              expectedRevision: 1, actor: "u", at: t0)
        }
    }
}
