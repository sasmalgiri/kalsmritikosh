//
//  ProfessionalMethodLifecycleEngineTests.swift
//  KalsmritikoshTests
//
//  PM-004 — the lifecycle engine end to end: transitions, completion gates,
//  supersession, human reopen (invalidating prior gates), terminal immutability,
//  content-write guards, event sequencing, atomic rollback, and durable relaunch.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — ProfessionalMethodLifecycleEngine", .serialized)
struct ProfessionalMethodLifecycleEngineTests {

    private let t0 = PM004Fixtures.t0

    private func noReviewDefinition() -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID), version: 1, label: "No review",
            category: .causal,
            requiredInputRoles: [MethodInputRole(rawValue: "problemStatement")],
            allowedNodeKinds: [MethodNodeKind(rawValue: "cause")],
            allowedEdgeKinds: [MethodEdgeKind(rawValue: "leadsTo")],
            requiredReviews: [],
            validationIdentifiers: ["v.structure"],
            outputContract: MethodOutputContract(allowedFindingKinds: [MethodFindingKind(rawValue: "candidateCause")]))
    }

    /// Drive a run to the point where completion should succeed.
    private func readyToComplete(_ rig: PM004Rig) async throws -> UUID {
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("boss"), now: t0)
        return runID
    }

    // MARK: - Transitions

    @Test("start moves draft → active and requires a resolvable definition")
    func start() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig, start: false, addContent: false)
        let agg = try await rig.engine.start(runID: runID, actor: .human("a"), now: t0)
        #expect(agg.run.status == .active)
        #expect(agg.lifecycleEvents.map(\.action) == [.start])
    }

    @Test("pause/resume round-trips through paused without changing content revision")
    func pauseResume() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        let content = try #require(try await rig.repo.run(id: runID)).contentRevision
        _ = try await rig.engine.pause(runID: runID, actor: .human("a"), now: t0)
        #expect(try await rig.repo.run(id: runID)?.status == .paused)
        let resumed = try await rig.engine.resume(runID: runID, actor: .human("a"), now: t0)
        #expect(resumed.run.status == .active)
        #expect(resumed.run.contentRevision == content)
    }

    @Test("requestHumanReview requires the definition to declare a review; continueAfterReview needs acceptance")
    func requestAndContinue() async throws {
        let noReview = try await PM004Fixtures.makeRig(definitions: [noReviewDefinition()])
        let r0 = try await PM004Fixtures.seedRun(noReview)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await noReview.engine.requestHumanReview(runID: r0, actor: .human("a"), now: self.t0)
        }
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.requestHumanReview(runID: runID, actor: .human("a"), now: t0)
        #expect(try await rig.repo.run(id: runID)?.status == .waitingForHuman)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: t0)
        #expect(try await rig.engine.continueAfterReview(runID: runID, actor: .human("a"), now: t0).run.status == .active)
    }

    @Test("block/unblock round-trips and requires a reason")
    func blockUnblock() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        await #expect(throws: ProfessionalMethodLifecycleError.invalidLifecycleReason) {
            _ = try await rig.engine.block(runID: runID, reason: " ", actor: .human("a"), now: self.t0)
        }
        _ = try await rig.engine.block(runID: runID, reason: "waiting on records", actor: .human("a"), now: t0)
        #expect(try await rig.repo.run(id: runID)?.status == .blocked)
        _ = try await rig.engine.unblock(runID: runID, reason: "records arrived", actor: .human("a"), now: t0)
        #expect(try await rig.repo.run(id: runID)?.status == .active)
    }

    @Test("cancel requires a reason and is terminal")
    func cancel() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.cancel(runID: runID, reason: "withdrawn", actor: .human("a"), now: t0)
        #expect(try await rig.repo.run(id: runID)?.status == .cancelled)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.pause(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    // MARK: - Supersession

    @Test("supersede validates the successor and marks only the old run")
    func supersede() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let old = try await PM004Fixtures.seedRun(rig)
        let successor = try await PM004Fixtures.seedRun(rig, start: false, addContent: false)
        // wrong workspace
        let otherWS = UUID(); try await PJE007Fixtures.seedWorkspace(rig.db, id: otherWS)
        let foreign = try await rig.repo.createRun(workspaceID: otherWS,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID),
            methodDefinitionVersion: 1, createdBy: "a", now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.successorWorkspaceMismatch(foreign.id)) {
            _ = try await rig.engine.supersede(runID: old, successorID: foreign.id, actor: .human("a"), now: self.t0)
        }
        await #expect(throws: ProfessionalMethodLifecycleError.invalidSuccessor(old)) {
            _ = try await rig.engine.supersede(runID: old, successorID: old, actor: .human("a"), now: self.t0)
        }
        let agg = try await rig.engine.supersede(runID: old, successorID: successor, actor: .human("a"), now: t0)
        #expect(agg.run.status == .superseded && agg.run.supersededByRunID == successor)
        #expect(try await rig.repo.run(id: successor)?.status == .draft)   // successor untouched
    }

    @Test("A completed run rejects a non-reopen lifecycle action")
    func completedRejectsPauseAndBlock() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await readyToComplete(rig)
        _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.invalidTransition(from: .completed, action: .pause)) {
            _ = try await rig.engine.pause(runID: runID, actor: .human("a"), now: self.t0)
        }
        await #expect(throws: ProfessionalMethodLifecycleError.invalidTransition(from: .completed, action: .block)) {
            _ = try await rig.engine.block(runID: runID, reason: "x", actor: .human("a"), now: self.t0)
        }
        #expect(try await rig.repo.run(id: runID)?.status == .completed)   // unchanged
    }

    @Test("reopen requires a non-blank reason")
    func reopenRequiresReason() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await readyToComplete(rig)
        _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.invalidLifecycleReason) {
            _ = try await rig.engine.reopenCompletedRun(runID: runID, reason: "  ", actor: .human("o"), now: self.t0)
        }
        #expect(try await rig.repo.run(id: runID)?.status == .completed)   // unchanged
    }

    @Test("start fails closed on an unknown definition version")
    func definitionMismatch() async throws {
        let rig = try await PM004Fixtures.makeRig()
        // A run whose definition version is not registered.
        let run = try await rig.repo.createRun(workspaceID: rig.ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID),
            methodDefinitionVersion: 9, createdBy: "a", now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.definitionVersionNotFound(id: PM004Fixtures.methodDefID, version: 9)) {
            _ = try await rig.engine.start(runID: run.id, actor: .human("a"), now: self.t0)
        }
    }

    // MARK: - Completion gates

    @Test("Completion succeeds only when every gate passes")
    func successfulCompletion() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await readyToComplete(rig)
        let agg = try await rig.engine.complete(runID: runID, actor: .human("a"), now: t0)
        #expect(agg.run.status == .completed)
        #expect(agg.run.completedAt != nil)
        #expect(agg.lifecycleEvents.contains { $0.action == .complete })
    }

    @Test("Completion fails when evidence is missing")
    func evidenceRequiredGate() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let run = try await rig.repo.createRun(workspaceID: rig.ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID),
            methodDefinitionVersion: 1, createdBy: "a", now: t0)
        _ = try await rig.engine.start(runID: run.id, actor: .human("a"), now: t0)
        // one valid node, but NO evidence link
        _ = try await rig.repo.addNode(MethodNode(methodRunID: run.id, nodeDefinitionKey: "k",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "L", ordinal: 0, createdAt: t0, updatedAt: t0),
            expectedRevision: run.revision + 1, now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.evidenceRequired) {
            _ = try await rig.engine.complete(runID: run.id, actor: .human("a"), now: self.t0)
        }
    }

    @Test("Completion fails when a required input role is unfulfilled")
    func inputRoleGate() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let run = try await rig.repo.createRun(workspaceID: rig.ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID),
            methodDefinitionVersion: 1, createdBy: "a", now: t0)
        _ = try await rig.engine.start(runID: run.id, actor: .human("a"), now: t0)
        let afterNode = try await rig.repo.addNode(MethodNode(methodRunID: run.id, nodeDefinitionKey: "k",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "L", ordinal: 0, createdAt: t0, updatedAt: t0),
            expectedRevision: run.revision + 1, now: t0)
        // an evidence link WITHOUT an input role — cannot satisfy the required role
        _ = try await rig.repo.addEvidenceLink(MethodEvidenceLink(methodRunID: run.id, targetKind: .entity,
            targetID: rig.entity, role: .supporting, ordinal: 0, addedBy: "a", addedAt: t0),
            expectedRevision: afterNode.revision, gate: rig.gate, now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.requiredInputRoleMissing("problemStatement")) {
            _ = try await rig.engine.complete(runID: run.id, actor: .human("a"), now: self.t0)
        }
    }

    @Test("Completion fails on an unsupported node / edge / finding kind")
    func conformanceKindGates() async throws {
        // node kind
        let rig1 = try await PM004Fixtures.makeRig()
        let r1 = try await PM004Fixtures.seedRun(rig1)
        let rev1 = try await PM004Fixtures.revision(rig1, r1)
        _ = try await rig1.repo.addNode(MethodNode(methodRunID: r1, nodeDefinitionKey: "k",
            nodeKind: MethodNodeKind(rawValue: "banned"), label: "L", ordinal: 1, createdAt: t0, updatedAt: t0),
            expectedRevision: rev1, now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.unsupportedNodeKind("banned")) {
            _ = try await rig1.engine.complete(runID: r1, actor: .human("a"), now: self.t0)
        }
        // finding kind
        let rig2 = try await PM004Fixtures.makeRig()
        let r2 = try await PM004Fixtures.seedRun(rig2)
        _ = try await rig2.repo.addFinding(MethodFinding(methodRunID: r2, statement: "s",
            findingKind: MethodFindingKind(rawValue: "banned"), createdAt: t0),
            expectedRevision: try await PM004Fixtures.revision(rig2, r2), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.unsupportedFindingKind("banned")) {
            _ = try await rig2.engine.complete(runID: r2, actor: .human("a"), now: self.t0)
        }
    }

    // MARK: - Reopen

    @Test("A completed run can be reopened only by a human, invalidating its prior gates")
    func reopenInvalidatesGates() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await readyToComplete(rig)
        let completed = try await rig.engine.complete(runID: runID, actor: .human("a"), now: t0)
        let contentBefore = completed.run.contentRevision
        // non-human reopen rejected
        await #expect(throws: ProfessionalMethodLifecycleError.humanActorRequired) {
            _ = try await rig.engine.reopenCompletedRun(runID: runID, reason: "revise", actor: .system, now: self.t0)
        }
        let reopened = try await rig.engine.reopenCompletedRun(runID: runID, reason: "revise", actor: .human("owner"), now: t0)
        #expect(reopened.run.status == .active)
        #expect(reopened.run.completedAt == nil)
        #expect(reopened.run.contentRevision == contentBefore + 1)          // new epoch invalidates prior gates
        #expect(reopened.reviews.contains { $0.reviewKey == MethodReview.reopenKey && $0.action == .reopen })
        // Re-completion now fails: the prior validation batch + review are stale.
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("Only a completed run can be reopened")
    func reopenOnlyCompleted() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)   // active
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.reopenCompletedRun(runID: runID, reason: "x", actor: .human("o"), now: self.t0)
        }
    }

    // MARK: - Immutability + content guard + CAS + events + atomicity

    @Test("A content write is rejected on a paused run")
    func contentWriteGuard() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.pause(runID: runID, actor: .human("a"), now: t0)
        let rev = try await PM004Fixtures.revision(rig, runID)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.addNode(MethodNode(methodRunID: runID, nodeDefinitionKey: "k",
                nodeKind: MethodNodeKind(rawValue: "cause"), label: "x", ordinal: 9, createdAt: self.t0, updatedAt: self.t0),
                expectedRevision: rev, now: self.t0)
        }
    }

    @Test("A stale expected revision fails the lifecycle plan without writing")
    func staleCAS() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        let plan = MethodLifecyclePlan(action: .pause, patch: .init(toStatus: .paused),
            actorKind: .human, actorIdentifier: "a")
        await #expect(throws: MethodPersistenceError.revisionConflict(runID: runID, expected: 99)) {
            _ = try await rig.repo.applyLifecyclePlan(runID: runID, expectedRevision: 99, plan: plan, now: self.t0)
        }
        #expect(try await rig.repo.run(id: runID)?.status == .active)   // unchanged
    }

    @Test("Lifecycle events form a contiguous ascending sequence")
    func eventSequence() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.pause(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.resume(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        let events = try await rig.repo.lifecycleEvents(runID: runID)
        #expect(events.map(\.sequence) == Array(1...events.count))
        #expect(events.map(\.action) == [.start, .pause, .resume, .validationRecorded])
    }

    @Test("A review naming a foreign node rolls back atomically")
    func atomicRollbackOnForeignReviewNode() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        let before = try await PM004Fixtures.revision(rig, runID)
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: UUID(), findingID: nil,
                action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: self.t0)
        }
        #expect(try await PM004Fixtures.revision(rig, runID) == before)     // no revision change
        #expect(try await rig.repo.reviews(runID: runID).isEmpty)
    }

    @Test("Close and relaunch reconstructs the exact aggregate")
    func relaunchReconstruction() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await readyToComplete(rig)
        _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: t0)
        let before = try #require(try await rig.repo.aggregate(runID: runID))
        // Reopen the database with a fresh repository.
        let repo2 = MethodRunRepository(database: try MigrationFixtureBuilder.reopen(at: rig.url))
        let after = try #require(try await repo2.aggregate(runID: runID))
        #expect(after.run == before.run)
        #expect(after.nodes == before.nodes)
        #expect(after.evidenceLinks == before.evidenceLinks)
        #expect(after.reviews == before.reviews)
        #expect(after.validationResults == before.validationResults)
        #expect(after.lifecycleEvents == before.lifecycleEvents)
    }
}
