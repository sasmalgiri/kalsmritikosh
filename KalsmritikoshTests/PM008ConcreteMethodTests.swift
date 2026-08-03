//
//  PM008ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-008 — Root-Cause Assessment (MET-07), CAPA (MET-08) and Effectiveness Review
//  (MET-09) driven end to end through the generic foundation. Proves the professional-truth
//  boundaries: a confirmed root cause requires a recorded human decision targeting it (the app never
//  confirms it); every CAPA action links its cause and closure is a human act; effectiveness is
//  evidence-backed and decided by an independent human review, never inferred. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-008 — Root-Cause + CAPA + Effectiveness", .serialized)
struct PM008ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

    private struct Rig {
        let repo: MethodRunRepository
        let engine: ProfessionalMethodLifecycleEngine
        let gate: CanonicalWorkflowEvidenceReferenceGate
        let ws: UUID
        let entity: UUID
    }

    private func makeRig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let repo = MethodRunRepository(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: scopes, scope: nil)
        let catalog = try await ProfessionalMethodCatalog.standard()
        let engine = await ProfessionalMethodLifecycleEngine(repository: repo, registry: catalog.methods, validators: catalog.validators)
        let ws = UUID(); try await PJE007Fixtures.seedWorkspace(db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(db, in: ws)
        return Rig(repo: repo, engine: engine, gate: gate, ws: ws, entity: entity)
    }

    private func rev(_ rig: Rig, _ runID: UUID) async throws -> Int {
        try await rig.repo.run(id: runID)?.revision ?? -1
    }

    private func startedRun(_ rig: Rig, id: ProfessionalMethodDefinitionID) async throws -> UUID {
        let run = try await rig.repo.createRun(workspaceID: rig.ws, methodDefinitionID: id,
                                               methodDefinitionVersion: 1, createdBy: "analyst", now: t0)
        _ = try await rig.engine.start(runID: run.id, actor: .human("analyst"), now: t0)
        return run.id
    }

    @discardableResult
    private func addNode(_ rig: Rig, _ runID: UUID, kind: MethodNodeKind, key: String, label: String,
                         body: String? = nil, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              body: body, ordinal: ordinal, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func nodeEvidence(_ rig: Rig, _ runID: UUID, node: UUID, role: MethodEvidenceLinkRole = .supporting, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: role, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    @discardableResult
    private func addFinding(_ rig: Rig, _ runID: UUID, node: UUID, kind: MethodFindingKind, statement: String) async throws -> UUID {
        let f = MethodFinding(methodRunID: runID, nodeID: node, statement: statement, findingKind: kind, createdAt: t0)
        _ = try await rig.repo.addFinding(f, expectedRevision: try await rev(rig, runID), now: t0)
        return f.id
    }

    private func review(_ rig: Rig, _ runID: UUID, key: String, findingID: UUID? = nil) async throws {
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: key, nodeID: nil, findingID: findingID,
                                              action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
    }

    // MARK: - Root-Cause Assessment

    @Test("A root cause is confirmed only by a recorded human decision targeting the finding")
    func rootCauseLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RootCauseAssessmentMethod.id)
        let c1 = try await addNode(rig, runID, kind: RootCauseAssessmentMethod.candidateCause, key: "c1", label: "Vendor SLA breach", ordinal: 0)
        try await nodeEvidence(rig, runID, node: c1, ordinal: 0)
        let finding = try await addFinding(rig, runID, node: c1, kind: RootCauseAssessmentMethod.confirmedRootCause,
                                           statement: "Vendor SLA breach is the root cause")
        try await review(rig, runID, key: RootCauseAssessmentMethod.decisionReviewKey, findingID: finding)  // human decision
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("The app cannot confirm a root cause without a human decision targeting that finding")
    func rootCauseBlocksAppConfirmation() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RootCauseAssessmentMethod.id)
        let c1 = try await addNode(rig, runID, kind: RootCauseAssessmentMethod.candidateCause, key: "c1", label: "Vendor SLA breach", ordinal: 0)
        try await nodeEvidence(rig, runID, node: c1, ordinal: 0)
        _ = try await addFinding(rig, runID, node: c1, kind: RootCauseAssessmentMethod.confirmedRootCause,
                                 statement: "Vendor SLA breach is the root cause")
        // A run-level decision review satisfies the review GATE but does NOT target the finding.
        try await review(rig, runID, key: RootCauseAssessmentMethod.decisionReviewKey, findingID: nil)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("Every candidate cause must carry an evidence profile")
    func rootCauseCandidateNeedsProfile() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RootCauseAssessmentMethod.id)
        let c1 = try await addNode(rig, runID, kind: RootCauseAssessmentMethod.candidateCause, key: "c1", label: "Profiled", ordinal: 0)
        try await nodeEvidence(rig, runID, node: c1, ordinal: 0)
        _ = try await addNode(rig, runID, kind: RootCauseAssessmentMethod.candidateCause, key: "c2", label: "Unprofiled", ordinal: 1)
        try await review(rig, runID, key: RootCauseAssessmentMethod.decisionReviewKey, findingID: nil)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - CAPA

    @Test("A CAPA completes when every action links its cause and closure is a human act")
    func capaLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: CAPAMethod.id)
        let a1 = try await addNode(rig, runID, kind: CAPAMethod.correctiveAction, key: "a1", label: "Renegotiate SLA", ordinal: 0)
        try await nodeEvidence(rig, runID, node: a1, role: .contextual, ordinal: 0)     // links the cause it addresses
        try await review(rig, runID, key: CAPAMethod.closureReviewKey)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("A CAPA action that links no cause blocks completion")
    func capaActionNeedsCause() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: CAPAMethod.id)
        let a1 = try await addNode(rig, runID, kind: CAPAMethod.correctiveAction, key: "a1", label: "Linked", ordinal: 0)
        try await nodeEvidence(rig, runID, node: a1, role: .contextual, ordinal: 0)
        _ = try await addNode(rig, runID, kind: CAPAMethod.preventiveAction, key: "a2", label: "Unlinked", ordinal: 1)
        try await review(rig, runID, key: CAPAMethod.closureReviewKey)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Effectiveness Review

    @Test("An effectiveness review completes with an evidence-backed check and a human decision")
    func effectivenessLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EffectivenessReviewMethod.id)
        let ck = try await addNode(rig, runID, kind: EffectivenessReviewMethod.check, key: "ck1", label: "SLA breach recurrence", body: "effective", ordinal: 0)
        try await nodeEvidence(rig, runID, node: ck, ordinal: 0)
        try await review(rig, runID, key: EffectivenessReviewMethod.decisionReviewKey)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("An ineffective outcome is a valid, evidence-backed effectiveness result")
    func effectivenessAllowsIneffective() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EffectivenessReviewMethod.id)
        let ck = try await addNode(rig, runID, kind: EffectivenessReviewMethod.check, key: "ck1", label: "Recurrence", body: "ineffective", ordinal: 0)
        try await nodeEvidence(rig, runID, node: ck, ordinal: 0)
        try await review(rig, runID, key: EffectivenessReviewMethod.decisionReviewKey)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)   // the method does not force an "effective" outcome
    }

    @Test("Effectiveness cannot be declared for a check with no evidence")
    func effectivenessCheckNeedsEvidence() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EffectivenessReviewMethod.id)
        let ck1 = try await addNode(rig, runID, kind: EffectivenessReviewMethod.check, key: "ck1", label: "Backed", ordinal: 0)
        try await nodeEvidence(rig, runID, node: ck1, ordinal: 0)
        _ = try await addNode(rig, runID, kind: EffectivenessReviewMethod.check, key: "ck2", label: "No evidence", ordinal: 1)
        try await review(rig, runID, key: EffectivenessReviewMethod.decisionReviewKey)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Catalog guard

    @Test("The catalog now registers nine methods; only Root-Cause records a (human-decided) finding")
    func catalogGrewToNine() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        #expect(catalog.methods.definition(id: RootCauseAssessmentMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: CAPAMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: EffectivenessReviewMethod.id, version: 1) != nil)
        #expect(catalog.methods.all.count >= 9)
        #expect(RootCauseAssessmentMethod().definition.outputContract.allowedFindingKinds == [RootCauseAssessmentMethod.confirmedRootCause])
        #expect(CAPAMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(EffectivenessReviewMethod().definition.outputContract.allowedFindingKinds.isEmpty)
    }
}
