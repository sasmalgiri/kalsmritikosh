//
//  WorkflowMethodExecutorContractTests.swift
//  KalsmritikoshTests
//
//  PJE-008 — the Stage 3 `.method` step driven through the execution engine as a
//  GENERIC adapter: it records an externally produced result and its explicit
//  canonical provenance, gate-verified and persisted atomically, without any
//  Stage 4 professional-method algorithm, Claim creation, or human decision.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-008 — method executor contract (engine-level)")
@MainActor
struct WorkflowMethodExecutorContractTests {

    private let t0 = PJE008Fixtures.t0

    private struct Rig {
        let base: PJE007Rig
        let runID: UUID
        let ws: UUID
        let entity: UUID
        let gap: UUID
    }

    /// A run started on a method step (blocking methodResultPresent), plus a
    /// seeded entity + gap in the workspace.
    private func startedMethodRun(suffix: String) async throws -> Rig {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let gap = try await PJE007Fixtures.seedGap(base.db)
        let pkg = try PJE008Fixtures.methodPackage(suffix: suffix)
        let runID = try await PJE008Fixtures.startMethodRun(base, package: pkg, workspaceID: ws, at: t0)
        return Rig(base: base, runID: runID, ws: ws, entity: entity, gap: gap)
    }

    private func methodStepRun(_ agg: ReopenedWorkflowRun) throws -> WorkflowStepRun {
        try #require(agg.stepRuns.first { $0.stepKind == .method })
    }

    private func decodeMethodState(_ stepRun: WorkflowStepRun) throws -> MethodStepState {
        try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<MethodStepState>.self, from: stepRun.stateJSON).state
    }

    // MARK: - 1: Valid adapter reference accepted

    @Test("A valid externally-produced method result is accepted and attached")
    func validResultAccepted() async throws {
        let r = try await startedMethodRun(suffix: "valid")
        _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "method.external.generic"), actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(10))
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(r.entity)], at: t0.addingTimeInterval(20))
        let after = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                                 actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        let state = try decodeMethodState(try methodStepRun(after))
        #expect(state.status == .resultAttached)
        #expect(state.result == result)
    }

    // MARK: - 2: Blank adapter ID rejected, nothing written

    @Test("A blank requested-method identifier is rejected with no state change")
    func blankAdapterRejected() async throws {
        let r = try await startedMethodRun(suffix: "blank")
        let before = try await r.base.repo.fetchRun(r.runID)
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.setRequestedMethod(
                methodDefinitionID: "   "), actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(10))
        }
        let after = try await r.base.repo.fetchRun(r.runID)
        #expect(after.run.revision == before.run.revision)
    }

    // MARK: - 3: Unknown adapter ID is opaque (accepted) — the Stage 3 contract

    @Test("An unknown method identifier is accepted as an opaque adapter reference")
    func unknownAdapterIsOpaque() async throws {
        let r = try await startedMethodRun(suffix: "opaque")
        let after = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "com.unknown.not-a-registered-method"),
            actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(10))
        let state = try decodeMethodState(try methodStepRun(after))
        #expect(state.requestedMethodDefinitionID == "com.unknown.not-a-registered-method")
    }

    // MARK: - 4: Cross-workspace evidence in the result fails closed

    @Test("A result whose provenance points at another workspace fails closed")
    func crossWorkspaceEvidenceFails() async throws {
        let r = try await startedMethodRun(suffix: "crossws")
        let wsB = UUID()
        try await PJE007Fixtures.seedWorkspace(r.base.db, id: wsB)
        let foreign = try await PJE007Fixtures.seedEntity(r.base.db, in: wsB)
        let before = try await r.base.repo.fetchRun(r.runID)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(foreign)], at: t0.addingTimeInterval(20))
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                             actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        }
        let after = try await r.base.repo.fetchRun(r.runID)
        #expect(after.run.revision == before.run.revision)
        #expect(try decodeMethodState(try methodStepRun(after)).result == nil)
    }

    // MARK: - 5: SensitiveScope-denied evidence fails closed

    @Test("A result whose provenance is SensitiveScope-denied fails closed")
    func scopeDeniedEvidenceFails() async throws {
        let r = try await startedMethodRun(suffix: "scopedenied")
        _ = try await r.base.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: r.entity),
            sensitivity: .confidential, authority: .systemRule(tag: "pje008"), reason: "t", at: t0)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(r.entity)], at: t0.addingTimeInterval(20))
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                             actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        }
    }

    // MARK: - 6: Missing provenance rejected — provenance is explicit

    @Test("A result declaring no provenance is rejected")
    func missingProvenanceRejected() async throws {
        let r = try await startedMethodRun(suffix: "noprov")
        let result = PJE008Fixtures.methodResult(provenance: [], at: t0.addingTimeInterval(20))
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                             actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        }
    }

    // MARK: - 7: Input + result provenance persist atomically

    @Test("Attaching a result persists method state and snapshotV1 provenance atomically")
    func resultAndProvenanceAtomic() async throws {
        let r = try await startedMethodRun(suffix: "atomic")
        let before = try await r.base.repo.fetchRun(r.runID)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(r.entity), PJE008Fixtures.gapRef(r.gap)],
            at: t0.addingTimeInterval(20))
        let after = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                                 actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        #expect(after.run.revision == before.run.revision + 1)
        #expect(after.run.revision == after.events.count)  // no extra provenance event
        let stepRunID = try methodStepRun(after).id
        let semantics = try await r.base.repo.provenanceSemantics(owner: .stepRun(stepRunID))
        #expect(semantics == .snapshotV1)
        let snap = try #require(try await r.base.repo.provenanceSnapshots(owner: .stepRun(stepRunID)).last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        #expect(Set(refs.map(\.canonicalObjectID)) == [r.entity, r.gap])
        #expect(refs.allSatisfy { $0.role == .methodInput })
    }

    // MARK: - 8: Failure leaves no partial state or provenance

    @Test("A failed attach leaves no partial state, result, or provenance snapshot")
    func failureLeavesNoPartialState() async throws {
        let r = try await startedMethodRun(suffix: "partial")
        let stepRunID = try methodStepRun(try await r.base.repo.fetchRun(r.runID)).id
        let snapsBefore = try await r.base.repo.provenanceSnapshots(owner: .stepRun(stepRunID)).count
        let wsB = UUID()
        try await PJE007Fixtures.seedWorkspace(r.base.db, id: wsB)
        let foreign = try await PJE007Fixtures.seedEntity(r.base.db, in: wsB)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(foreign)], at: t0.addingTimeInterval(20))
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                             actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        }
        let after = try await r.base.repo.fetchRun(r.runID)
        #expect(try decodeMethodState(try methodStepRun(after)).status == .awaitingResult)
        #expect(try await r.base.repo.provenanceSnapshots(owner: .stepRun(stepRunID)).count == snapsBefore)
    }

    // MARK: - 9: removeResult then reattach (append-only correction of generic state)

    @Test("Removing a result and attaching a new one replaces the generic state")
    func removeThenReattach() async throws {
        let r = try await startedMethodRun(suffix: "reattach")
        let first = PJE008Fixtures.methodResult(
            resultRef: "ext-result-A", provenance: [PJE008Fixtures.entityRef(r.entity)], at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(first),
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.removeResult,
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(30))
        let second = PJE008Fixtures.methodResult(
            resultRef: "ext-result-B", provenance: [PJE008Fixtures.gapRef(r.gap)], at: t0.addingTimeInterval(40))
        let after = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(second),
                                                 actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(40))
        let state = try decodeMethodState(try methodStepRun(after))
        #expect(state.result?.resultReferenceID == "ext-result-B")
    }

    // MARK: - 10: A method result never becomes a Claim

    @Test("Attaching a method result never mutates the canonical claims table")
    func resultNeverBecomesClaim() async throws {
        let r = try await startedMethodRun(suffix: "noclaim")
        let claimsBefore = Int(try await r.base.db.query("SELECT COUNT(*) FROM claims;", []).first?.int(0) ?? -1)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(r.entity)], at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.attachResult(result),
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        let claimsAfter = Int(try await r.base.db.query("SELECT COUNT(*) FROM claims;", []).first?.int(0) ?? -2)
        #expect(claimsAfter == claimsBefore)
    }

    // MARK: - 11: Completion requires a result

    @Test("Completing a method step without a result is blocked with no state change")
    func completionRequiresResult() async throws {
        let r = try await startedMethodRun(suffix: "needresult")
        let before = try await r.base.repo.fetchRun(r.runID)
        await #expect(throws: (any Error).self) {
            _ = try await PJE007Fixtures.exec(r.base, runID: r.runID, MethodStepCommand.complete,
                                             actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        }
        let after = try await r.base.repo.fetchRun(r.runID)
        #expect(after.run.revision == before.run.revision)
        #expect(after.run.status != .completed)
    }

    // MARK: - 12: Result state reopens byte-exact

    @Test("An attached result reopens byte-exact over the same file")
    func resultReopensExactly() async throws {
        let url = PJE007Fixtures.newURL()
        let base = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let pkg = try PJE008Fixtures.methodPackage(suffix: "reopen")
        let runID = try await PJE008Fixtures.startMethodRun(base, package: pkg, workspaceID: ws, at: t0)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(entity)], at: t0.addingTimeInterval(20))
        let after = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.attachResult(result),
                                                 actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        let beforeJSON = try methodStepRun(after).stateJSON

        let rig2 = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        let reopened = try await rig2.repo.fetchRun(runID)
        let reopenedStep = try methodStepRun(reopened)
        #expect(reopenedStep.stateJSON == beforeJSON)
        #expect(try decodeMethodState(reopenedStep).result == result)
    }

    // MARK: - 13: Completion cannot bypass a downstream approval gate

    @Test("Completing the method step advances to the approval gate, not to completion")
    func completionCannotBypassApprovalGate() async throws {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let pkg = try PJE008Fixtures.methodApprovalPackage(suffix: "gate")
        let runID = try await PJE008Fixtures.startMethodRun(base, package: pkg, workspaceID: ws, at: t0)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(entity)], at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.attachResult(result),
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        let atApproval = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.complete,
                                                      actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(30))
        #expect(atApproval.run.status != .completed)
        #expect(atApproval.stepRuns.contains { $0.stepKind == .humanApproval && $0.status == .active })
    }

    // MARK: - 14: Human review requires an authorized human actor

    @Test("The downstream approval requires an authorized human role; system/wrong role fails")
    func humanReviewRequiresAuthorizedActor() async throws {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let pkg = try PJE008Fixtures.methodApprovalPackage(suffix: "role", approverRoles: ["reviewer"])
        let runID = try await PJE008Fixtures.startMethodRun(base, package: pkg, workspaceID: ws, at: t0)
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(entity)], at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.attachResult(result),
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.complete,
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(30))
        _ = try await PJE007Fixtures.exec(base, runID: runID, HumanApprovalStepCommand.setPrompt("Approve the method result?"),
                                         actor: .system, at: t0.addingTimeInterval(35))
        _ = try await PJE007Fixtures.exec(base, runID: runID, HumanApprovalStepCommand.requestApproval,
                                         actor: .system, at: t0.addingTimeInterval(40))
        // Wrong role fails.
        await #expect(throws: (any Error).self) {
            _ = try await base.engine.submitHumanApproval(
                runID: runID, approved: true, rationale: "ok",
                actor: PJE007Fixtures.human("someone", role: "not-reviewer"), at: t0.addingTimeInterval(50))
        }
        // Authorized role succeeds and continues.
        let approved = try await base.engine.submitHumanApproval(
            runID: runID, approved: true, rationale: "ok",
            actor: PJE007Fixtures.human("rev-1", role: "reviewer"), at: t0.addingTimeInterval(60))
        #expect(approved.run.status == .active || approved.run.status == .completed)
    }

    // MARK: - 15: Malformed command writes nothing

    @Test("A malformed method command writes neither state nor provenance")
    func malformedCommandNoWrite() async throws {
        let r = try await startedMethodRun(suffix: "malformed")
        let before = try await r.base.repo.fetchRun(r.runID)
        await #expect(throws: (any Error).self) {
            _ = try await r.base.engine.executeCommand(
                runID: r.runID, commandJSON: "{\"type\":\"bogus\"}",
                actor: PJE007Fixtures.human("a"), now: t0.addingTimeInterval(20))
        }
        let after = try await r.base.repo.fetchRun(r.runID)
        #expect(after.run.revision == before.run.revision)
    }
}
