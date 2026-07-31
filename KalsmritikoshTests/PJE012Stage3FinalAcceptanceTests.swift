//
//  PJE012Stage3FinalAcceptanceTests.swift
//  KalsmritikoshTests
//
//  PJE-012 — Stage 3 (Persona Job Engine) FINAL ACCEPTANCE.
//
//  This is an audit / closure / evidence unit, not a feature. It adds the
//  narrowly-missing final checks that close Stage 3 and formally resolves the
//  two carried rulings, WITHOUT changing any production contract:
//
//   1. reviewEvidence disposition contract — CLOSED as intentional.
//      role = .reviewed; disposition ∈ {active, needsFollowUp,
//      excludedFromWorkflow}. Supporting/contradicting polarity is a property
//      of claim/evidence assessment, NOT of review provenance, so the .reviewed
//      role never carries it.
//
//   2. `.brokenLineage` — DOCUMENTED as a reserved defensive state. The guarded
//      inspector path validates canonical existence FIRST and reports a missing
//      target as `.unresolved`; the `.brokenLineage` availability branch is not
//      claimed as a normal reachable Stage 3 product state. Wherever a broken
//      lineage DOES arise (the SensitiveScope layer), it resolves to a denial
//      that carries no label, and the inspector strips every annotation from any
//      inaccessible reference — so it can never leak information.
//
//  The primary connected acceptance case remains PJE-011; here we add only the
//  final cross-unit checks PJE-011 does not already assert.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-012 — Stage 3 final acceptance", .serialized)
@MainActor
struct PJE012Stage3FinalAcceptanceTests {

    private let t0 = PJE011Fixtures.t0

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Ruling 1: reviewEvidence disposition contract (intentional)

    @Test("The review vocabulary is a closed, intentional set; polarity is a separate role family")
    func reviewDispositionVocabularyIsClosedAndIntentional() {
        // The provenance disposition emitted by a review is exactly these three.
        #expect(Set(WorkflowProvenanceDisposition.allCases) == [.active, .needsFollowUp, .excludedFromWorkflow])
        // The reviewEvidence input status vocabulary is exactly these three.
        #expect(Set(WorkflowEvidenceReviewStatus.allCases) == [.reviewed, .needsFollowUp, .excludedFromThisWorkflow])
        // Supporting / contradicting polarity exists ONLY as a separate role
        // family — it is never a review disposition. This is the closed ruling.
        #expect(WorkflowProvenanceRole.allCases.contains(.supporting))
        #expect(WorkflowProvenanceRole.allCases.contains(.contradicting))
        #expect(WorkflowProvenanceRole.reviewed != WorkflowProvenanceRole.supporting)
        #expect(WorkflowProvenanceRole.reviewed != WorkflowProvenanceRole.contradicting)
    }

    @Test("reviewEvidence provenance uses the .reviewed role only — never supporting/contradicting polarity")
    func reviewEvidenceProvenanceUsesReviewedRoleNeverPolarity() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "reviewruling")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        let run = try await a.rig.repo.fetchRun(c.runID)
        let reviewStep = try #require(run.stepRuns.first { $0.stepKind == .reviewEvidence })
        let inspector = WorkflowProvenanceInspector(
            repository: a.rig.repo, database: a.rig.db, scopes: a.rig.scopes)
        let inspection = try await inspector.inspect(
            owner: .stepRun(reviewStep.id),
            access: PJE006CFixtures.exportAccess(workspaceID: c.ws.id))
        #expect(!inspection.references.isEmpty)
        for reference in inspection.references {
            #expect(reference.role == .reviewed)
            #expect(reference.role != .supporting)
            #expect(reference.role != .contradicting)
            #expect([.active, .needsFollowUp, .excludedFromWorkflow].contains(reference.disposition))
        }
    }

    // MARK: - Ruling 2: .brokenLineage is a reserved defensive state that never leaks

    @Test("A broken lineage resolves to a denial that carries no protection label to expose")
    func brokenLineageResolvesToDenialCarryingNoLabel() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "brokenlabel")
        // At the layer where a broken lineage genuinely arises — an unknown
        // canonical target — the scope resolves to `.brokenLineage`, NOT a
        // `.resolved(label)`. There is therefore no label to leak.
        let resolution = try await c.rig.scopes.effectiveLabel(
            for: SensitiveScopeTarget(kind: .claim, id: UUID()))
        #expect(resolution == .brokenLineage)
        if case .resolved = resolution {
            Issue.record("a broken lineage must never resolve to an exposable protection label")
        }
    }

    @Test("An inaccessible provenance reference exposes no annotations (the strip path brokenLineage shares)")
    func inspectorInaccessibleReferenceExposesNoAnnotations() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "noleak")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        let inspector = WorkflowProvenanceInspector(
            repository: a.rig.repo, database: a.rig.db, scopes: a.rig.scopes)
        let exportAccess = PJE006CFixtures.exportAccess(workspaceID: c.ws.id)
        let before = try await inspector.inspect(owner: .artifact(a.wpArtifactID), access: exportAccess)
        let citedSV = try #require(before.references.first { $0.kind == .sourceVersion })
        #expect(citedSV.availability == .available)

        // Seal the cited source, then inspect under public access. The reference
        // stays visible (counts honest) but every annotation is stripped — the
        // identical code path a reserved `.brokenLineage` reference would take.
        _ = try await a.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: citedSV.canonicalObjectID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje012"), reason: "sealed", at: t0)
        let publicAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: c.ws.id, maximumSensitivity: .publicLevel,
            permitsPrivilegedMaterial: false, purpose: .export))
        let after = try await inspector.inspect(owner: .artifact(a.wpArtifactID), access: publicAccess)
        let denied = try #require(after.references.first { $0.canonicalObjectID == citedSV.canonicalObjectID })
        #expect(denied.availability == .accessDenied)
        #expect(denied.label == nil)
        #expect(denied.note == nil)
        #expect(denied.locatorJSON == nil)
        #expect(denied.sourceVersionID == nil)
        #expect(after.inaccessibleReferenceCount >= 1)
    }

    @Test("The provenance availability vocabulary enumerates the reserved brokenLineage state distinctly")
    func provenanceAvailabilityEnumeratesReservedBrokenLineage() {
        // Not CaseIterable by design; assert the four states are mutually
        // distinct so the reserved defensive `.brokenLineage` cannot silently
        // collapse into an exposing state.
        let states: [WorkflowProvenanceReferenceAvailability] =
            [.available, .accessDenied, .unresolved, .brokenLineage]
        #expect(Set(states.map { "\($0)" }).count == 4)
        #expect(WorkflowProvenanceReferenceAvailability.brokenLineage != .available)
        #expect(WorkflowProvenanceReferenceAvailability.brokenLineage != .unresolved)
    }

    // MARK: - Final acceptance: 17 kinds bind stable executor identities

    @Test("All 17 step kinds bind to a stable, distinct executor identity handling exactly that kind")
    func allSeventeenKindsBindStableExecutorIdentity() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let registry = try PJE006CFixtures.makeFullRegistry(gate: gate)
        #expect(WorkflowStepKind.allCases.count == 17)
        var identities = Set<String>()
        for kind in WorkflowStepKind.allCases {
            let executor = try #require(
                registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: kind),
                "no executor bound for \(kind.rawValue)")
            #expect(executor.handledKind == kind)
            let id = executor.executorID.rawValue
            let version = executor.executorVersion.rawValue
            #expect(!id.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!version.trimmingCharacters(in: .whitespaces).isEmpty)
            identities.insert("\(id)@\(version)")
        }
        #expect(identities.count == 17)   // every kind has its own stable identity
    }

    // MARK: - Final acceptance: automation proposal coexists with a connected, approved run

    @Test("A safe automation proposes an unconfirmed candidate that coexists with an approved connected run and touches no canonical truth")
    func automationProposalCoexistsWithApprovedConnectedRun() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "finalconnected")
        let claimsBefore = try await count(c.rig.db, "claims")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)

        // Safe automation on the same live run: a proposal, never a confirmation.
        let validator = WorkflowProvenanceReferenceValidator(
            gate: CanonicalWorkflowEvidenceReferenceGate(
                database: c.rig.db, scopeRepository: c.rig.scopes, scope: nil),
            database: c.rig.db)
        let coordinator = PersonaAutomationRuntimeCoordinator(
            executions: WorkflowAutomationExecutionRepository(database: c.rig.db),
            workflowRuns: c.rig.repo, tasks: ProfessionalTaskRepository(database: c.rig.db),
            deadlines: DeadlineRepository(database: c.rig.db), validator: validator)
        let def = PersonaAutomationDefinition(
            id: PJE011Fixtures.automationID, version: 1, label: "Evidence request",
            trigger: .workflowEvent, action: .createMissingEvidenceRequest)
        let outcome = try await coordinator.run(
            definition: def, applicationID: PJE011Fixtures.appID,
            request: PersonaAutomationRequest(
                workspaceID: c.ws.id, workflowRunID: c.runID, title: "Need the carrier record"),
            trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "final-blocked"),
            now: a.lastTime.addingTimeInterval(5))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let taskID = try #require(exec.outputID)

        // Approve and advance the connected run past its human-approval gate.
        var time = a.lastTime.addingTimeInterval(10)
        _ = try await a.rig.engine.submitHumanApproval(
            runID: c.runID, approved: true, rationale: "all findings cited",
            actor: PJE011Fixtures.human("boss", role: "supervisor"), at: time)
        time.addTimeInterval(10)
        let approved = try await PJE011Fixtures.exec(
            a.rig, runID: c.runID, HumanApprovalStepCommand.applyRecordedApproval, at: time)
        #expect(approved.decisions.contains { $0.kind == .humanApproval && $0.selectedOption == "approved" })

        // The candidate persists across a relaunch, still unconfirmed, and no
        // canonical claim was created by any of this.
        let rig2 = try await PJE011Fixtures.reopen(c)
        let row = try await rig2.db.query(
            "SELECT status, origin FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        #expect(row.first?.string(0) == "candidate")             // never opened/completed
        #expect(row.first?.string(1) == "automationProposed")
        #expect(try await count(rig2.db, "claims") == claimsBefore)
    }
}
