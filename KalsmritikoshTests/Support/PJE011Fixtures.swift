//
//  PJE011Fixtures.swift
//  KalsmritikoshTests
//
//  PJE-011 — one authoritative test-only synthetic persona package + seeding for
//  a COMPLETE Stage 3 workflow that exercises the integrated lifecycle:
//  intake(attachment) → selectEvidence → reviewEvidence → timeline → method →
//  decision → workProductBuild → effectivenessReview → humanApproval → closure.
//
//  It runs through the real WorkflowDefinitionCompiler, registries, lifecycle
//  engine, executors, provenance bridge, work-product assembly and automation
//  runtime — no production shortcut.
//

import Foundation
@testable import Kalsmritikosh

struct PJE011Case {
    let rig: PJE006CRig
    let ws: Workspace
    let fileID: UUID
    let entityID: UUID
    let gapID: UUID
    let attachment: PJE007Fixtures.SeededSource
    let runID: UUID
    let contractHash: String
}

enum PJE011Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_900_000)
    static let appID = ApplicationDefinitionID(rawValue: "stage3.synthetic.acceptance")
    static let wfID = WorkflowDefinitionID(rawValue: "stage3.synthetic.case-completion")
    static let attachmentArtifactDefID = "art.synthetic.attachment"
    static let automationID = AutomationDefinitionID(rawValue: "stage3.synthetic.evidence-request")

    static func human(_ id: String, role: String? = nil) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: role)
    }

    // MARK: - The synthetic workflow package

    static func syntheticPackage(
        suffix: String = "main"
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            intake: StepDefinitionID(rawValue: "step.intake.\(suffix)"),
            select: StepDefinitionID(rawValue: "step.select.\(suffix)"),
            review: StepDefinitionID(rawValue: "step.review.\(suffix)"),
            timeline: StepDefinitionID(rawValue: "step.timeline.\(suffix)"),
            method: StepDefinitionID(rawValue: "step.method.\(suffix)"),
            decision: StepDefinitionID(rawValue: "step.decision.\(suffix)"),
            build: StepDefinitionID(rawValue: "step.build.\(suffix)"),
            effectiveness: StepDefinitionID(rawValue: "step.effectiveness.\(suffix)"),
            approval: StepDefinitionID(rawValue: "step.approval.\(suffix)"),
            closure: StepDefinitionID(rawValue: "step.closure.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)"),
            rejected: StepDefinitionID(rawValue: "step.rejected.\(suffix)")
        )
        let steps: [PersonaWorkflowStepDefinition] = [
            PersonaWorkflowStepDefinition(
                id: ids.intake, kind: .intake, label: "Intake", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.select)],
                artifacts: [PersonaWorkflowArtifactDefinition(
                    id: attachmentArtifactDefID, label: "Attached source",
                    workProductTemplateID: nil, isRequired: false)]),
            PersonaWorkflowStepDefinition(
                id: ids.select, kind: .selectEvidence, label: "Select evidence",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.review)]),
            PersonaWorkflowStepDefinition(
                id: ids.review, kind: .reviewEvidence, label: "Review evidence",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.timeline)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.reviewed", kind: .evidenceReviewed, label: "All evidence reviewed", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.timeline, kind: .timeline, label: "Timeline",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.method)]),
            PersonaWorkflowStepDefinition(
                id: ids.method, kind: .method, label: "Method",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.decision)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.method-result", kind: .methodResultPresent, label: "Method result attached", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.decision, kind: .decision, label: "Decide",
                transitions: [
                    WorkflowTransitionDefinition(label: "proceed", targetStepID: ids.build),
                    WorkflowTransitionDefinition(label: "halt", targetStepID: ids.done)
                ],
                decisionBranches: ["proceed", "halt"]),
            PersonaWorkflowStepDefinition(
                id: ids.build, kind: .workProductBuild, label: "Build",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.effectiveness)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.artifact", kind: .artifactGenerated, label: "Report generated", isBlocking: true)],
                artifacts: [PersonaWorkflowArtifactDefinition(
                    id: PJE006CFixtures.artifactDefID, label: "Summary report",
                    workProductTemplateID: PJE006CFixtures.wpDefID, isRequired: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.effectiveness, kind: .effectivenessReview, label: "Effectiveness",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.approval)]),
            PersonaWorkflowStepDefinition(
                id: ids.approval, kind: .humanApproval, label: "Approve",
                transitions: [
                    WorkflowTransitionDefinition(label: "approved", targetStepID: ids.closure),
                    WorkflowTransitionDefinition(label: "rejected", targetStepID: ids.rejected)
                ],
                approverRoles: ["supervisor"]),
            PersonaWorkflowStepDefinition(
                id: ids.closure, kind: .closure, label: "Closure",
                transitions: [WorkflowTransitionDefinition(label: "finish", targetStepID: ids.done)]),
            PersonaWorkflowStepDefinition(id: ids.done, kind: .closure, label: "Done", isTerminal: true),
            PersonaWorkflowStepDefinition(id: ids.rejected, kind: .closure, label: "Rejected", isTerminal: true)
        ]
        let wfID = WorkflowDefinitionID(rawValue: "stage3.synthetic.case-completion.\(suffix)")
        let appID = ApplicationDefinitionID(rawValue: "stage3.synthetic.acceptance.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Synthetic case completion", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "stage3.synthetic.term.\(suffix)")
        let term = PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID, labels: [.issue: "Matter", .task: "Action item"])
        let wp = PersonaWorkProductDefinition(
            id: WorkProductDefinitionID(rawValue: PJE006CFixtures.wpDefID),
            version: 1, label: "General summary", template: .generalSummary)
        let automation = PersonaAutomationDefinition(
            id: AutomationDefinitionID(rawValue: "stage3.synthetic.evidence-request.\(suffix)"),
            version: 1, label: "Missing evidence request", trigger: .workflowEvent, action: .createMissingEvidenceRequest)
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "Synthetic acceptance app"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [RegistryKey(id: wp.id, version: wp.version)], workProducts: [wp],
            validatorKeys: [], validators: [],
            automationKeys: [RegistryKey(id: automation.id, version: automation.version)],
            automations: [automation])
        return (pkg, wfID)
    }

    // MARK: - Synthetic evidence + case creation

    /// Seed a composable workspace (backfilled claims for the work product), an
    /// entity + gap (for selection/timeline), and a canonical attachment source
    /// version, then create and start the synthetic run.
    @MainActor
    static func makeCase(suffix: String = "main") async throws -> PJE011Case {
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "shipment delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let entityID = try await PJE007Fixtures.seedEntity(rig.db, in: ws.id)
        let gapID = try await PJE007Fixtures.seedGap(rig.db)
        let attachment = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws.id)
        let (pkg, wfID) = try syntheticPackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: "Synthetic case", parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0.addingTimeInterval(5))
        return PJE011Case(
            rig: rig, ws: ws, fileID: fileID, entityID: entityID, gapID: gapID,
            attachment: attachment, runID: created.run.id,
            contractHash: created.run.contractSnapshotSHA256)
    }

    @MainActor
    static func reopen(_ c: PJE011Case) async throws -> PJE006CRig {
        try await PJE006CFixtures.makeRig(at: c.rig.dbURL, migrate: false)
    }

    static func exec(
        _ rig: PJE006CRig, runID: UUID, _ command: some Encodable,
        actor: WorkflowLifecycleActor = .system, at time: Date
    ) async throws -> ReopenedWorkflowRun {
        try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(command), actor: actor, now: time)
    }

    /// A generic externally-produced method result citing the gap.
    static func methodResult(gapID: UUID, at: Date) -> WorkflowMethodResultReference {
        WorkflowMethodResultReference(
            providerID: "com.external.provider", providerVersion: "1.0",
            methodDefinitionID: "method.external.timeline-analysis",
            methodRunReferenceID: "ext-run-1", resultReferenceID: "ext-result-1",
            summary: "Delay attributable to carrier handoff",
            provenanceReferences: [WorkflowMethodProvenanceReference(objectKind: "gap", canonicalObjectID: gapID.uuidString)],
            completedBy: "analyst-1", completedAt: at, limitations: ["one carrier record"])
    }

    struct AtApproval {
        let rig: PJE006CRig
        let attachmentArtifactID: UUID
        let wpArtifactID: UUID
        let wpRunID: UUID
        var lastTime: Date
    }

    /// Drive the synthetic workflow from a fresh case all the way to the
    /// waiting-for-approval state (attachment + evidence + method + decision +
    /// build + effectiveness + requestApproval). Returns the case + key IDs.
    @MainActor
    static func driveToApprovalWaiting(_ c: PJE011Case) async throws -> AtApproval {
        let rig = c.rig
        var time = t0.addingTimeInterval(10)
        let coordinator = WorkflowAttachmentCoordinator(
            workflowRuns: rig.repo, database: rig.db,
            sourceRelations: SourceRelationsRepository(database: rig.db),
            gate: CanonicalWorkflowEvidenceReferenceGate(database: rig.db, scopeRepository: rig.scopes, scope: nil),
            scopes: rig.scopes)
        let afterAttach = try await coordinator.attachCanonicalSource(
            runID: c.runID,
            request: WorkflowCanonicalAttachmentRequest(
                artifactDefinitionID: attachmentArtifactDefID, sourceVersionID: c.attachment.svID, displayName: "invoice.pdf"),
            actor: human("analyst"), at: time)
        let attachmentArtifactID = afterAttach.artifacts.first!.id
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, IntakeStepCommand.setTitle("Matter"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: c.entityID.uuidString, reason: "subject"), at: time)
        time.addTimeInterval(10)
        let afterSelect = try await exec(rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .gap, canonicalObjectID: c.gapID.uuidString, reason: "gap"), at: time)
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: afterSelect.stepRuns.first { $0.id == afterSelect.run.currentStepRunID }!.stateJSON).state.items
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, SelectEvidenceStepCommand.complete, at: time)
        for item in items {
            time.addTimeInterval(10)
            _ = try await exec(rig, runID: c.runID, ReviewEvidenceStepCommand.review(itemID: item.id, status: .reviewed, note: "s"), at: time)
        }
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, ReviewEvidenceStepCommand.complete, at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: c.entityID.uuidString, label: "x",
            dateISO8601: "2025-02-01T00:00:00Z", datePrecision: .day, uncertaintyNote: nil, conflictingDates: []), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, TimelineStepCommand.complete, at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "m.ext"), actor: human("analyst"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, MethodStepCommand.attachResult(
            methodResult(gapID: c.gapID, at: time)), actor: human("analyst"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, MethodStepCommand.complete, actor: human("analyst"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, DecisionStepCommand.setQuestion("Proceed?"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, DecisionStepCommand.setOptions(options: ["proceed", "halt"], mode: .humanRequired), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, DecisionStepCommand.requestHumanDecision, at: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.submitHumanDecision(
            runID: c.runID, decisionKey: "gate", selectedOption: "proceed", rationale: "ok",
            basis: [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: c.entityID, role: .decisionBasis)],
            actor: human("case-owner"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, DecisionStepCommand.applyRecordedDecision, at: time)
        time.addTimeInterval(10)
        let built = try await exec(rig, runID: c.runID, WorkProductBuildStepCommand.build(buildRequest(c.ws)), actor: human("case-owner"), at: time)
        let wpArtifact = built.artifacts.first { $0.kind == .workProductRun }!
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, WorkProductBuildStepCommand.complete, actor: human("case-owner"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, EffectivenessReviewStepCommand.recordAssessment(
            assessment: .effective, rationale: "ok", followUpRequired: false, followUpNote: nil), actor: human("qa"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, EffectivenessReviewStepCommand.complete, actor: human("qa"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, HumanApprovalStepCommand.setPrompt("Release?"), at: time)
        time.addTimeInterval(10); _ = try await exec(rig, runID: c.runID, HumanApprovalStepCommand.requestApproval, at: time)
        return AtApproval(rig: rig, attachmentArtifactID: attachmentArtifactID,
                          wpArtifactID: wpArtifact.id, wpRunID: wpArtifact.workProductRunID!, lastTime: time)
    }

    static func buildRequest(_ ws: Workspace) -> WorkflowWorkProductBuildRequest {
        WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
    }
}
