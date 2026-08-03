//
//  PM007ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-007 — Five Whys (MET-05) and Fishbone / Ishikawa (MET-06) driven end to end through
//  the generic foundation. Proves: a Five Whys chain may only deepen from a supported level (evidence
//  OR an explicit assumption) and otherwise stops honestly — it never forces five levels without
//  support, and never records a confirmed root cause; a fishbone needs at least one branch populated
//  with a candidate cause and never declares a bone the confirmed root cause. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-007 — Five Whys + Fishbone", .serialized)
struct PM007ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_762_000_000)

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

    private func startedRun(_ rig: Rig, id: ProfessionalMethodDefinitionID, version: Int,
                            anchorRole: MethodInputRole) async throws -> UUID {
        let run = try await rig.repo.createRun(workspaceID: rig.ws, methodDefinitionID: id,
                                               methodDefinitionVersion: version, createdBy: "analyst", now: t0)
        _ = try await rig.engine.start(runID: run.id, actor: .human("analyst"), now: t0)
        let anchor = MethodEvidenceLink(methodRunID: run.id, nodeID: nil, targetKind: .entity, targetID: rig.entity,
                                        role: .supporting, inputRole: anchorRole, ordinal: 0, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(anchor, expectedRevision: try await rev(rig, run.id), gate: rig.gate, now: t0)
        return run.id
    }

    @discardableResult
    private func addNode(_ rig: Rig, _ runID: UUID, kind: MethodNodeKind, key: String, label: String,
                         parent: UUID? = nil, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              ordinal: ordinal, parentNodeID: parent, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func nodeEvidence(_ rig: Rig, _ runID: UUID, node: UUID, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: .supporting, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    private func addAssumption(_ rig: Rig, _ runID: UUID, node: UUID, statement: String) async throws {
        let a = MethodAssumption(methodRunID: runID, nodeID: node, statement: statement, createdBy: "analyst")
        _ = try await rig.repo.addAssumption(a, expectedRevision: try await rev(rig, runID), now: t0)
    }

    private func confirm(_ rig: Rig, _ runID: UUID, key: String) async throws {
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: key, nodeID: nil, findingID: nil,
                                              action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
    }

    // MARK: - Five Whys

    @Test("A Five Whys chain completes when every deepened level is supported and the leaf stops honestly")
    func fiveWhysLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveWhysMethod.id, version: 1, anchorRole: FiveWhysMethod.problemRole)
        let w1 = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w1", label: "Shipment was late", ordinal: 0)
        try await nodeEvidence(rig, runID, node: w1, ordinal: 1)                              // w1 supported → may deepen
        _ = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w2", label: "Carrier missed pickup", parent: w1, ordinal: 2)  // leaf, honest stop
        try await confirm(rig, runID, key: FiveWhysMethod.confirmReviewKey)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("Five Whys blocks deepening from an unsupported level (no forced five levels)")
    func fiveWhysBlocksUnsupportedDeepening() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveWhysMethod.id, version: 1, anchorRole: FiveWhysMethod.problemRole)
        let w1 = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w1", label: "Shipment was late", ordinal: 0)  // NO support
        _ = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w2", label: "Guessed deeper cause", parent: w1, ordinal: 1)
        try await confirm(rig, runID, key: FiveWhysMethod.confirmReviewKey)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("An explicit assumption legitimately supports deepening a Five Whys level")
    func fiveWhysAssumptionAllowsDeepening() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveWhysMethod.id, version: 1, anchorRole: FiveWhysMethod.problemRole)
        let w1 = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w1", label: "Shipment was late", ordinal: 0)
        try await addAssumption(rig, runID, node: w1, statement: "Assume the carrier SLA governs pickup timing")
        _ = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w2", label: "SLA pickup window was infeasible", parent: w1, ordinal: 1)
        try await confirm(rig, runID, key: FiveWhysMethod.confirmReviewKey)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("Five Whys never records a confirmed root cause (no findings allowed)")
    func fiveWhysRejectsFinding() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveWhysMethod.id, version: 1, anchorRole: FiveWhysMethod.problemRole)
        let w1 = try await addNode(rig, runID, kind: FiveWhysMethod.why, key: "w1", label: "Late", ordinal: 0)
        try await nodeEvidence(rig, runID, node: w1, ordinal: 1)
        let finding = MethodFinding(methodRunID: runID, statement: "Carrier is the root cause",
                                    findingKind: MethodFindingKind(rawValue: "rootCause"), createdAt: t0)
        _ = try await rig.repo.addFinding(finding, expectedRevision: try await rev(rig, runID), now: t0)
        try await confirm(rig, runID, key: FiveWhysMethod.confirmReviewKey)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Fishbone

    @Test("A fishbone completes with a branch populated by a candidate cause")
    func fishboneLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FishboneMethod.id, version: 1, anchorRole: FishboneMethod.problemRole)
        let branch = try await addNode(rig, runID, kind: FishboneMethod.branch, key: "b1", label: "Logistics", ordinal: 0)
        _ = try await addNode(rig, runID, kind: FishboneMethod.candidateCause, key: "c1", label: "Carrier scheduling", parent: branch, ordinal: 1)
        try await confirm(rig, runID, key: FishboneMethod.confirmReviewKey)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("A fishbone with an empty branch cannot complete")
    func fishboneNeedsPopulatedBranch() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FishboneMethod.id, version: 1, anchorRole: FishboneMethod.problemRole)
        _ = try await addNode(rig, runID, kind: FishboneMethod.branch, key: "b1", label: "Logistics", ordinal: 0)
        try await confirm(rig, runID, key: FishboneMethod.confirmReviewKey)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A fishbone never declares a bone the confirmed root cause (no findings allowed)")
    func fishboneRejectsFinding() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FishboneMethod.id, version: 1, anchorRole: FishboneMethod.problemRole)
        let branch = try await addNode(rig, runID, kind: FishboneMethod.branch, key: "b1", label: "Logistics", ordinal: 0)
        _ = try await addNode(rig, runID, kind: FishboneMethod.candidateCause, key: "c1", label: "Carrier scheduling", parent: branch, ordinal: 1)
        let finding = MethodFinding(methodRunID: runID, statement: "Carrier scheduling is the root cause",
                                    findingKind: MethodFindingKind(rawValue: "rootCause"), createdAt: t0)
        _ = try await rig.repo.addFinding(finding, expectedRevision: try await rev(rig, runID), now: t0)
        try await confirm(rig, runID, key: FishboneMethod.confirmReviewKey)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Catalog guard

    @Test("The catalog now registers six concrete methods, the causal pair producing no root cause")
    func catalogGrewToSix() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        #expect(catalog.methods.definition(id: FiveWhysMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: FishboneMethod.id, version: 1) != nil)
        #expect(catalog.methods.all.count >= 6)
        #expect(FiveWhysMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(FishboneMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(FiveWhysMethod().definition.category == .causal)
        #expect(FishboneMethod().definition.category == .causal)
    }
}
