//
//  PJE010Fixtures.swift
//  KalsmritikoshTests
//
//  PJE-010 — shared automation runtime rig over the PJE-007 workflow rig.
//

import Foundation
@testable import Kalsmritikosh

struct PJE010Rig {
    let base: PJE007Rig
    let tasks: ProfessionalTaskRepository
    let deadlines: DeadlineRepository
    let executions: WorkflowAutomationExecutionRepository
    let coordinator: PersonaAutomationRuntimeCoordinator
    var db: Database { base.db }
    var workflowRuns: WorkflowRunRepository { base.repo }
    var scopes: SensitiveScopeRepository { base.scopes }
}

enum PJE010Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_800_000)
    static let applicationID = ApplicationDefinitionID(rawValue: "com.pje010.app")

    static func makeRig(at url: URL, migrate: Bool = true) async throws -> PJE010Rig {
        let base = try await PJE007Fixtures.makeRig(at: url, migrate: migrate)
        // The PJE-007 rig pins v77; PJE-010 needs the v78 automation execution
        // ledger. migrate() is idempotent and self-heals to the latest schema.
        try await SchemaMigrations.migrate(base.db)
        let tasks = ProfessionalTaskRepository(database: base.db)
        let deadlines = DeadlineRepository(database: base.db)
        let executions = WorkflowAutomationExecutionRepository(database: base.db)
        let coordinator = PersonaAutomationRuntimeCoordinator(
            executions: executions, workflowRuns: base.repo,
            tasks: tasks, deadlines: deadlines, validator: base.validator)
        return PJE010Rig(base: base, tasks: tasks, deadlines: deadlines,
                         executions: executions, coordinator: coordinator)
    }

    static func automation(
        id: String = "auto.gap-request", version: Int = 1,
        trigger: PersonaAutomationTriggerKind = .workflowEvent,
        action: PersonaAutomationActionKind
    ) -> PersonaAutomationDefinition {
        PersonaAutomationDefinition(
            id: AutomationDefinitionID(rawValue: id), version: version,
            label: "Automation", trigger: trigger, action: action)
    }

    /// Seed a workspace and start a minimal workflow run; returns (workspaceID, runID).
    @MainActor
    static func startRun(_ rig: PJE010Rig, suffix: String) async throws -> (ws: UUID, runID: UUID) {
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "auto-\(suffix)")
        let created = try await rig.workflowRuns.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.base.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        return (ws, created.run.id)
    }

    /// A candidate task to hang a candidate deadline off.
    static func seedTask(_ rig: PJE010Rig, ws: UUID) async throws -> UUID {
        let task = try await rig.tasks.createCandidate(
            workspaceID: ws, primaryIssueID: nil, title: "Target", detail: nil,
            type: .action, priority: .normal, owner: nil,
            origin: .automationProposed, proposedBy: "seed", at: t0)
        return task.id
    }

    static func dayDeadline(_ date: Date = t0) -> DeadlineValue {
        DeadlineValue(date: date, precision: .day, timeZoneIdentifier: "UTC")
    }
}
