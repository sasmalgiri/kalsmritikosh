//
//  PM010ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-010 — Risk Matrix (MET-15) and Decision Matrix (MET-16), completing the professional
//  method catalog (MET-01..16). Proves: every risk rating cites its basis and no rating is a certain
//  outcome (no findings); every decision option's scores cite their basis, and a selected option is
//  admitted only by a recorded HUMAN decision targeting it — the app never makes the final decision.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-010 — Risk + Decision matrices", .serialized)
struct PM010ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_765_000_000)

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
    private func addNode(_ rig: Rig, _ runID: UUID, kind: MethodNodeKind, key: String, label: String, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              ordinal: ordinal, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func nodeEvidence(_ rig: Rig, _ runID: UUID, node: UUID, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: .supporting, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
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

    // MARK: - Risk Matrix

    @Test("A risk matrix completes when every rated item cites its basis")
    func riskLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RiskMatrixMethod.id)
        let item = try await addNode(rig, runID, kind: RiskMatrixMethod.riskItem, key: "r1", label: "Vendor insolvency (likely/high)", ordinal: 0)
        try await nodeEvidence(rig, runID, node: item, ordinal: 0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        try await review(rig, runID, key: RiskMatrixMethod.reviewKey)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("A risk rating with no cited basis blocks completion")
    func riskRatingNeedsBasis() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RiskMatrixMethod.id)
        let cited = try await addNode(rig, runID, kind: RiskMatrixMethod.riskItem, key: "r1", label: "Cited", ordinal: 0)
        try await nodeEvidence(rig, runID, node: cited, ordinal: 0)
        _ = try await addNode(rig, runID, kind: RiskMatrixMethod.riskItem, key: "r2", label: "Guessed rating", ordinal: 1)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        try await review(rig, runID, key: RiskMatrixMethod.reviewKey)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Decision Matrix

    @Test("A decision matrix records a chosen option only via a recorded human decision")
    func decisionLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: DecisionMatrixMethod.id)
        let opt = try await addNode(rig, runID, kind: DecisionMatrixMethod.option, key: "o1", label: "Switch vendor", ordinal: 0)
        try await nodeEvidence(rig, runID, node: opt, ordinal: 0)
        let finding = try await addFinding(rig, runID, node: opt, kind: DecisionMatrixMethod.selectedOption, statement: "Switch vendor is the chosen option")
        try await review(rig, runID, key: DecisionMatrixMethod.decisionReviewKey, findingID: finding)   // human decision
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("The app cannot select an option without a human decision targeting that finding")
    func decisionBlocksAppSelection() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: DecisionMatrixMethod.id)
        let opt = try await addNode(rig, runID, kind: DecisionMatrixMethod.option, key: "o1", label: "Switch vendor", ordinal: 0)
        try await nodeEvidence(rig, runID, node: opt, ordinal: 0)
        _ = try await addFinding(rig, runID, node: opt, kind: DecisionMatrixMethod.selectedOption, statement: "Chosen")
        // A run-level decision review satisfies the gate but does not target the finding.
        try await review(rig, runID, key: DecisionMatrixMethod.decisionReviewKey, findingID: nil)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A decision option whose scores cite no basis blocks completion")
    func decisionOptionNeedsBasis() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: DecisionMatrixMethod.id)
        let cited = try await addNode(rig, runID, kind: DecisionMatrixMethod.option, key: "o1", label: "Cited", ordinal: 0)
        try await nodeEvidence(rig, runID, node: cited, ordinal: 0)
        _ = try await addNode(rig, runID, kind: DecisionMatrixMethod.option, key: "o2", label: "Unscored", ordinal: 1)
        try await review(rig, runID, key: DecisionMatrixMethod.decisionReviewKey, findingID: nil)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Catalog guard — Stage B complete

    @Test("The catalog now registers all sixteen professional methods (MET-01..16)")
    func catalogComplete() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        #expect(catalog.methods.definition(id: RiskMatrixMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: DecisionMatrixMethod.id, version: 1) != nil)
        #expect(catalog.methods.all.count == 16)
        #expect(RiskMatrixMethod().definition.outputContract.allowedFindingKinds.isEmpty)  // a rating is not a certain outcome
        #expect(DecisionMatrixMethod().definition.outputContract.allowedFindingKinds == [DecisionMatrixMethod.selectedOption])
        #expect(RiskMatrixMethod().definition.category == .decision)
        #expect(DecisionMatrixMethod().definition.category == .decision)
    }
}
