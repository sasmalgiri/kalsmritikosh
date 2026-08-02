//
//  PM005ConcreteMethodTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-005 — the first two CONCRETE methods (Brainstorming, 5W1H) driven end-to-end through
//  the generic PM-001..004 foundation: create → start → anchor evidence → items/slots → validate →
//  review → complete → reopen. Proves the professional-truth rules deterministically: brainstorming
//  produces only proposals (a finding is rejected; an in-method promotion blocks), and 5W1H blocks a
//  slot answered without evidence while allowing an explicitly-unknown slot. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-005 — concrete methods (Brainstorming, 5W1H)", .serialized)
struct PM005ConcreteMethodTests {

    private let t0 = Date(timeIntervalSince1970: 1_760_500_000)

    private struct Rig {
        let db: Database
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
        return Rig(db: db, repo: repo, engine: engine, gate: gate, ws: ws, entity: entity)
    }

    private func rev(_ rig: Rig, _ runID: UUID) async throws -> Int {
        try await rig.repo.run(id: runID)?.revision ?? -1
    }

    /// Create a started run of `method` and attach the required anchor evidence link.
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
                         body: String? = nil, state: MethodWorkingState = .proposal, ordinal: Int) async throws -> UUID {
        let node = MethodNode(methodRunID: runID, nodeDefinitionKey: key, nodeKind: kind, label: label,
                              body: body, workingState: state, ordinal: ordinal, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(node, expectedRevision: try await rev(rig, runID), now: t0)
        return node.id
    }

    private func addSlotEvidence(_ rig: Rig, _ runID: UUID, node: UUID, ordinal: Int) async throws {
        let link = MethodEvidenceLink(methodRunID: runID, nodeID: node, targetKind: .entity, targetID: rig.entity,
                                      role: .supporting, inputRole: nil, ordinal: ordinal, addedBy: "analyst", addedAt: t0)
        _ = try await rig.repo.addEvidenceLink(link, expectedRevision: try await rev(rig, runID), gate: rig.gate, now: t0)
    }

    // MARK: - Catalog

    @Test("The standard catalog registers Brainstorming and 5W1H with their validators")
    func catalogAssembles() async throws {
        let catalog = try await ProfessionalMethodCatalog.standard()
        #expect(catalog.methods.definition(id: BrainstormingMethod.id, version: 1) != nil)
        #expect(catalog.methods.definition(id: FiveW1HMethod.id, version: 1) != nil)
        #expect(catalog.validators.validator(id: BrainstormingValidator.identifier) != nil)
        #expect(catalog.validators.validator(id: FiveW1HValidator.identifier) != nil)
    }

    // MARK: - Brainstorming

    @Test("A brainstorm completes with typed proposals and reopens cleanly")
    func brainstormingLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: BrainstormingMethod.id, version: 1, anchorRole: BrainstormingMethod.caseContextRole)
        _ = try await addNode(rig, runID, kind: BrainstormingMethod.idea, key: "i1", label: "Check the handoff log", ordinal: 0)
        _ = try await addNode(rig, runID, kind: BrainstormingMethod.question, key: "q1", label: "Who approved it?", ordinal: 1)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
        // Reopen is a human act that bumps the content revision (invalidating prior gates).
        let reopened = try await rig.engine.reopenCompletedRun(runID: runID, reason: "add a lead", actor: .human("lead"), now: t0)
        #expect(reopened.run.status == .active)
        #expect(reopened.run.contentRevision == done.run.contentRevision + 1)
    }

    @Test("A brainstorm rejects a finding — it produces only proposals, never facts")
    func brainstormingRejectsFinding() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: BrainstormingMethod.id, version: 1, anchorRole: BrainstormingMethod.caseContextRole)
        _ = try await addNode(rig, runID, kind: BrainstormingMethod.idea, key: "i1", label: "Idea", ordinal: 0)
        let finding = MethodFinding(methodRunID: runID, statement: "The handoff caused it",
                                    findingKind: MethodFindingKind(rawValue: "conclusion"), createdAt: t0)
        _ = try await rig.repo.addFinding(finding, expectedRevision: try await rev(rig, runID), now: t0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        // The conformance gate rejects any finding (the output contract allows none).
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A brainstorm blocks an item promoted to a fact inside the method")
    func brainstormingBlocksInMethodPromotion() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: BrainstormingMethod.id, version: 1, anchorRole: BrainstormingMethod.caseContextRole)
        _ = try await addNode(rig, runID, kind: BrainstormingMethod.hypothesis, key: "h1", label: "It was the vendor",
                              state: .humanAcceptedForWorkflow, ordinal: 0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A brainstorm with no items cannot complete")
    func brainstormingNeedsAnItem() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: BrainstormingMethod.id, version: 1, anchorRole: BrainstormingMethod.caseContextRole)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    // MARK: - 5W1H

    @Test("A 5W1H worksheet completes when answered slots cite evidence and unknown slots are marked")
    func fiveW1HLifecycle() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveW1HMethod.id, version: 1, anchorRole: FiveW1HMethod.subjectRole)
        // who: answered + cited
        let who = try await addNode(rig, runID, kind: FiveW1HMethod.who, key: "who", label: "Who", body: "Alice", ordinal: 0)
        try await addSlotEvidence(rig, runID, node: who, ordinal: 1)
        // why: honestly unknown
        _ = try await addNode(rig, runID, kind: FiveW1HMethod.why, key: "why", label: "Why", state: .gap, ordinal: 2)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: FiveW1HMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil,
                                              actor: .human("reviewer"), now: t0)
        let done = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: t0)
        #expect(done.run.status == .completed)
    }

    @Test("A 5W1H slot answered without evidence blocks completion (no fabricated answers)")
    func fiveW1HBlocksFabricatedAnswer() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveW1HMethod.id, version: 1, anchorRole: FiveW1HMethod.subjectRole)
        _ = try await addNode(rig, runID, kind: FiveW1HMethod.what, key: "what", label: "What", body: "A bribe", ordinal: 0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: FiveW1HMethod.confirmReviewKey, nodeID: nil,
                                              findingID: nil, action: .acceptForWorkflow, comment: nil,
                                              actor: .human("reviewer"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }

    @Test("A 5W1H run cannot complete without the confirm-slots human review")
    func fiveW1HRequiresReview() async throws {
        let rig = try await makeRig()
        let runID = try await startedRun(rig, id: FiveW1HMethod.id, version: 1, anchorRole: FiveW1HMethod.subjectRole)
        let who = try await addNode(rig, runID, kind: FiveW1HMethod.who, key: "who", label: "Who", body: "Alice", ordinal: 0)
        try await addSlotEvidence(rig, runID, node: who, ordinal: 1)
        _ = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        // No confirmSlots review recorded → the review gate fails.
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("analyst"), now: self.t0)
        }
    }
}
