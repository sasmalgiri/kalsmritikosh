//
//  PM009ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-009 — the analytical pack (Contradiction Matrix, Gap Analysis, Timeline Analysis,
//  Relationship Analysis, Transaction Flow) driven end to end. Proves each method's citation
//  discipline and that none asserts a conclusion (no findings): a contradiction preserves both sides,
//  a gap states a reason, a dated timeline row cites its source (or is marked undated), a
//  relationship cites evidence, and a transaction traces its amount to a source. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-009 — analytical method pack", .serialized)
struct PM009ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_764_000_000)

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

    private func anchor(_ rig: Rig, _ runID: UUID, role: MethodInputRole, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: nil, targetKind: .entity, targetID: rig.entity,
                                      role: .supporting, inputRole: role, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    @discardableResult
    private func addNode(_ rig: Rig, _ runID: UUID, kind: MethodNodeKind, key: String, label: String,
                         body: String? = nil, state: MethodWorkingState = .proposal, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              body: body, workingState: state, ordinal: ordinal, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func nodeEvidence(_ rig: Rig, _ runID: UUID, node: UUID, role: MethodEvidenceLinkRole = .supporting, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: role, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    private func confirmAndComplete(_ rig: Rig, _ runID: UUID, key: String) async throws -> MethodRunAggregate {
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: key, nodeID: nil, findingID: nil,
                                              action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        return try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
    }

    private func expectBlocked(_ rig: Rig, _ runID: UUID, key: String) async throws {
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: key, nodeID: nil, findingID: nil,
                                              action: .acceptForWorkflow, comment: nil, actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - Contradiction Matrix

    @Test("A contradiction completes only with both sides preserved")
    func contradictionLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: ContradictionMatrixMethod.id)
        let c = try await addNode(rig, runID, kind: ContradictionMatrixMethod.conflict, key: "x", label: "Account A vs B", ordinal: 0)
        try await nodeEvidence(rig, runID, node: c, role: .supporting, ordinal: 0)
        try await nodeEvidence(rig, runID, node: c, role: .contradicting, ordinal: 1)
        #expect(try await confirmAndComplete(rig, runID, key: ContradictionMatrixMethod.reviewKey).run.status == .completed)
    }

    @Test("A contradiction missing a side blocks completion")
    func contradictionMissingSideBlocks() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: ContradictionMatrixMethod.id)
        let c = try await addNode(rig, runID, kind: ContradictionMatrixMethod.conflict, key: "x", label: "One-sided", ordinal: 0)
        try await nodeEvidence(rig, runID, node: c, role: .supporting, ordinal: 0)   // only one side
        try await expectBlocked(rig, runID, key: ContradictionMatrixMethod.reviewKey)
    }

    // MARK: - Gap Analysis

    @Test("A gap analysis completes with a reasoned gap and a stated searched scope")
    func gapLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: GapAnalysisMethod.id)
        try await anchor(rig, runID, role: GapAnalysisMethod.searchedScopeRole, ordinal: 0)
        _ = try await addNode(rig, runID, kind: GapAnalysisMethod.gap, key: "g", label: "No Q2 invoices", body: "Q2 invoices matter for the payment timeline", ordinal: 0)
        #expect(try await confirmAndComplete(rig, runID, key: GapAnalysisMethod.reviewKey).run.status == .completed)
    }

    @Test("A gap with no stated reason blocks completion")
    func gapWithoutReasonBlocks() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: GapAnalysisMethod.id)
        try await anchor(rig, runID, role: GapAnalysisMethod.searchedScopeRole, ordinal: 0)
        _ = try await addNode(rig, runID, kind: GapAnalysisMethod.gap, key: "g", label: "Empty", body: "  ", ordinal: 0)
        try await expectBlocked(rig, runID, key: GapAnalysisMethod.reviewKey)
    }

    // MARK: - Timeline Analysis

    @Test("A timeline completes when dated rows are cited and undated rows are marked")
    func timelineLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: TimelineAnalysisMethod.id)
        let dated = try await addNode(rig, runID, kind: TimelineAnalysisMethod.row, key: "r1", label: "Contract signed 2024-03-01", ordinal: 0)
        try await nodeEvidence(rig, runID, node: dated, ordinal: 0)
        _ = try await addNode(rig, runID, kind: TimelineAnalysisMethod.row, key: "r2", label: "Verbal agreement", state: .gap, ordinal: 1)  // undated
        #expect(try await confirmAndComplete(rig, runID, key: TimelineAnalysisMethod.reviewKey).run.status == .completed)
    }

    @Test("A dated timeline row with no citation blocks completion (no invented dates)")
    func timelineDatedRowNeedsCitation() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: TimelineAnalysisMethod.id)
        let cited = try await addNode(rig, runID, kind: TimelineAnalysisMethod.row, key: "r1", label: "Cited", ordinal: 0)
        try await nodeEvidence(rig, runID, node: cited, ordinal: 0)
        _ = try await addNode(rig, runID, kind: TimelineAnalysisMethod.row, key: "r2", label: "Invented date 2024-05-05", ordinal: 1)  // dated, no citation, not undated
        try await expectBlocked(rig, runID, key: TimelineAnalysisMethod.reviewKey)
    }

    // MARK: - Relationship Analysis

    @Test("A relationship analysis completes when each edge cites evidence")
    func relationshipLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RelationshipAnalysisMethod.id)
        let e = try await addNode(rig, runID, kind: RelationshipAnalysisMethod.relationship, key: "e", label: "Alice → Acme (director)", ordinal: 0)
        try await nodeEvidence(rig, runID, node: e, ordinal: 0)
        #expect(try await confirmAndComplete(rig, runID, key: RelationshipAnalysisMethod.reviewKey).run.status == .completed)
    }

    @Test("A relationship with no evidence blocks completion")
    func relationshipNeedsEvidence() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: RelationshipAnalysisMethod.id)
        let cited = try await addNode(rig, runID, kind: RelationshipAnalysisMethod.relationship, key: "e1", label: "Cited", ordinal: 0)
        try await nodeEvidence(rig, runID, node: cited, ordinal: 0)
        _ = try await addNode(rig, runID, kind: RelationshipAnalysisMethod.relationship, key: "e2", label: "Asserted, no evidence", ordinal: 1)
        try await expectBlocked(rig, runID, key: RelationshipAnalysisMethod.reviewKey)
    }

    // MARK: - Transaction Flow

    @Test("A transaction flow completes when each transaction traces to a source")
    func transactionLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: TransactionFlowMethod.id)
        _ = try await addNode(rig, runID, kind: TransactionFlowMethod.party, key: "p1", label: "Acme", ordinal: 0)
        let txn = try await addNode(rig, runID, kind: TransactionFlowMethod.transaction, key: "t1", label: "₹1,00,000 on 2024-04-02", ordinal: 1)
        try await nodeEvidence(rig, runID, node: txn, ordinal: 0)
        #expect(try await confirmAndComplete(rig, runID, key: TransactionFlowMethod.reviewKey).run.status == .completed)
    }

    @Test("A transaction whose amount does not trace to a source blocks completion")
    func transactionNeedsSource() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: TransactionFlowMethod.id)
        let traced = try await addNode(rig, runID, kind: TransactionFlowMethod.transaction, key: "t1", label: "Traced", ordinal: 0)
        try await nodeEvidence(rig, runID, node: traced, ordinal: 0)
        _ = try await addNode(rig, runID, kind: TransactionFlowMethod.transaction, key: "t2", label: "Untraced amount", ordinal: 1)
        try await expectBlocked(rig, runID, key: TransactionFlowMethod.reviewKey)
    }

    // MARK: - Catalog guard

    @Test("The catalog now registers fourteen methods; the analytical pack produces no findings")
    func catalogGrewToFourteen() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        for id in [ContradictionMatrixMethod.id, GapAnalysisMethod.id, TimelineAnalysisMethod.id,
                   RelationshipAnalysisMethod.id, TransactionFlowMethod.id] {
            #expect(catalog.methods.definition(id: id, version: 1) != nil)
        }
        #expect(catalog.methods.all.count >= 14)
        #expect(ContradictionMatrixMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(GapAnalysisMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(TimelineAnalysisMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(RelationshipAnalysisMethod().definition.outputContract.allowedFindingKinds.isEmpty)
        #expect(TransactionFlowMethod().definition.outputContract.allowedFindingKinds.isEmpty)
    }
}
