//
//  PM006ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-006 — Hypothesis Matrix (MET-03) and Evidence Collection Plan (MET-04) driven end to
//  end through the generic foundation. Proves: every hypothesis must carry an evidence profile and
//  the app never records a winning hypothesis (no findings allowed); an evidence request states a
//  need and may not assert the sought evidence already exists. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-006 — Hypothesis Matrix + Evidence Collection Plan", .serialized)
struct PM006ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_761_000_000)

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

    private func startedRun(_ rig: Rig, id: ProfessionalMethodDefinitionID, version: Int) async throws -> UUID {
        let run = try await rig.repo.createRun(workspaceID: rig.ws, methodDefinitionID: id,
                                               methodDefinitionVersion: version, createdBy: "analyst", now: t0)
        _ = try await rig.engine.start(runID: run.id, actor: .human("analyst"), now: t0)
        return run.id
    }

    private func anchor(_ rig: Rig, _ runID: UUID, role: MethodInputRole, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: nil, targetKind: .entity, targetID: rig.entity,
                                      role: .supporting, inputRole: role, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    @discardableResult
    private func addNode(_ rig: Rig, _ runID: UUID, kind: MethodNodeKind, key: String, label: String,
                         body: String? = nil, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              body: body, ordinal: ordinal, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func nodeEvidence(_ rig: Rig, _ runID: UUID, node: UUID, role: MethodEvidenceLinkRole, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: role, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    // MARK: - Hypothesis Matrix

    @Test("A hypothesis matrix completes when every hypothesis carries an evidence profile")
    func hypothesisMatrixLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: HypothesisMatrixMethod.id, version: 1)
        let h1 = try await addNode(rig, runID, kind: HypothesisMatrixMethod.hypothesis, key: "h1", label: "Vendor caused the delay", ordinal: 0)
        try await nodeEvidence(rig, runID, node: h1, role: .supporting, ordinal: 0)     // FOR
        let h2 = try await addNode(rig, runID, kind: HypothesisMatrixMethod.hypothesis, key: "h2", label: "Internal process caused it", ordinal: 1)
        try await nodeEvidence(rig, runID, node: h2, role: .contradicting, ordinal: 1)  // AGAINST
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: HypothesisMatrixMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("A hypothesis without an evidence profile blocks completion")
    func hypothesisWithoutProfileBlocks() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: HypothesisMatrixMethod.id, version: 1)
        let h1 = try await addNode(rig, runID, kind: HypothesisMatrixMethod.hypothesis, key: "h1", label: "H1", ordinal: 0)
        try await nodeEvidence(rig, runID, node: h1, role: .supporting, ordinal: 0)
        _ = try await addNode(rig, runID, kind: HypothesisMatrixMethod.hypothesis, key: "h2", label: "H2 (no profile)", ordinal: 1)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: HypothesisMatrixMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A hypothesis matrix never records a winning hypothesis (no findings allowed)")
    func hypothesisMatrixRejectsFinding() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: HypothesisMatrixMethod.id, version: 1)
        let h1 = try await addNode(rig, runID, kind: HypothesisMatrixMethod.hypothesis, key: "h1", label: "H1", ordinal: 0)
        try await nodeEvidence(rig, runID, node: h1, role: .supporting, ordinal: 0)
        let finding = MethodFinding(methodRunID: runID, statement: "H1 is the true cause",
                                    findingKind: MethodFindingKind(rawValue: "winner"), createdAt: t0)
        _ = try await rig.repo.addFinding(finding, expectedRevision: try await rev(rig, runID), now: t0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: HypothesisMatrixMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Evidence Collection Plan

    @Test("An evidence collection plan completes with described requests")
    func evidencePlanLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EvidenceCollectionPlanMethod.id, version: 1)
        try await anchor(rig, runID, role: EvidenceCollectionPlanMethod.caseContextRole, ordinal: 0)
        _ = try await addNode(rig, runID, kind: EvidenceCollectionPlanMethod.request, key: "r1",
                              label: "Bank statements", body: "Obtain the vendor's bank statements for Q2", ordinal: 0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: EvidenceCollectionPlanMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("An evidence request may not assert the sought evidence already exists")
    func evidencePlanBlocksAssertingEvidence() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EvidenceCollectionPlanMethod.id, version: 1)
        try await anchor(rig, runID, role: EvidenceCollectionPlanMethod.caseContextRole, ordinal: 0)
        let r1 = try await addNode(rig, runID, kind: EvidenceCollectionPlanMethod.request, key: "r1",
                                   label: "Statements", body: "Obtain bank statements", ordinal: 0)
        try await nodeEvidence(rig, runID, node: r1, role: .supporting, ordinal: 1)   // asserts it exists
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: EvidenceCollectionPlanMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("An evidence request must describe its need")
    func evidencePlanRequestNeedsNeed() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: EvidenceCollectionPlanMethod.id, version: 1)
        try await anchor(rig, runID, role: EvidenceCollectionPlanMethod.caseContextRole, ordinal: 0)
        _ = try await addNode(rig, runID, kind: EvidenceCollectionPlanMethod.request, key: "r1", label: "Empty", body: "   ", ordinal: 0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: EvidenceCollectionPlanMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Catalog guards

    @Test("The catalog now registers four concrete methods, all producing no auto-facts")
    func catalogGrewToFour() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        #expect(catalog.methods.definition(id: HypothesisMatrixMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: EvidenceCollectionPlanMethod.id, version: 1) != nil)
        #expect(catalog.methods.all.count >= 4)
        #expect(HypothesisMatrixMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(EvidenceCollectionPlanMethod().definition.outputContract.allowedFindingKinds.isEmpty)
    }
}
