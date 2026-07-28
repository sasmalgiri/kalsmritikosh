//
//  MethodStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — MethodStepExecutor: adapter-only method boundary, result reference
//  validation, .methodResultPresent facts. 11 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — MethodStepExecutor")
@MainActor
struct MethodStepExecutorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_600_000)

    private func methodReq(id: String = "req.method") -> PersonaWorkflowRequirement {
        PersonaWorkflowRequirement(
            id: id, kind: .methodResultPresent, label: "Method result", isBlocking: true)
    }

    private func rigAndState(
        reqs: [PersonaWorkflowRequirement] = [],
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (MethodStepExecutor, ExecutorTestRig, String) {
        let executor = MethodStepExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .method, reqs: reqs)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func validResult(
        provenance: [WorkflowMethodProvenanceReference]? = nil,
        completedBy: String = "analyst-1",
        summary: String = "Five factors ruled out; supplier change remains plausible"
    ) -> WorkflowMethodResultReference {
        WorkflowMethodResultReference(
            providerID: "com.external.method-provider",
            providerVersion: "2.3",
            methodDefinitionID: "method.external.analysis",
            methodRunReferenceID: "run-889",
            resultReferenceID: "result-889-1",
            summary: summary,
            provenanceReferences: provenance ?? [
                WorkflowMethodProvenanceReference(
                    objectKind: "entity", canonicalObjectID: UUID().uuidString)
            ],
            completedBy: completedBy,
            completedAt: t0,
            limitations: ["Single-source corroboration"])
    }

    private func attachJSON(_ result: WorkflowMethodResultReference) throws -> String {
        try WorkflowStepPayloadCodec.encode(MethodStepCommand.attachResult(result))
    }

    @Test("Preparation creates awaiting-result state with unsatisfied method facts")
    func prepareAwaitingResult() async throws {
        let (_, _, stateJSON) = try await rigAndState(reqs: [methodReq()])
        let state = try decodeEnvelopeState(MethodStepState.self, from: stateJSON)
        #expect(state.status == .awaitingResult)
        #expect(state.result == nil)
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: stateJSON)
        #expect(header.requirementFacts.count == 1)
        #expect(header.requirementFacts[0].kind == .methodResultPresent)
        #expect(header.requirementFacts[0].isSatisfied == false)
    }

    @Test("Blank requested method ID is rejected")
    func blankMethodIDRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(
            MethodStepCommand.setRequestedMethod(methodDefinitionID: "   "))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Result attachment round-trips with exact reference identity")
    func resultAttachmentRoundTrips() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let result = validResult()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(context: ctx, commandJSON: try attachJSON(result))
        let state = try decodeEnvelopeState(MethodStepState.self, from: r.stateJSON)
        #expect(state.status == .resultAttached)
        #expect(state.result == result)
    }

    @Test("Missing provider identity is rejected")
    func missingProviderIdentityRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let bad = WorkflowMethodResultReference(
            providerID: " ", providerVersion: "1",
            methodDefinitionID: "m", methodRunReferenceID: "r", resultReferenceID: "res",
            summary: "s",
            provenanceReferences: [WorkflowMethodProvenanceReference(
                objectKind: "entity", canonicalObjectID: UUID().uuidString)],
            completedBy: "a", completedAt: t0, limitations: [])
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try attachJSON(bad))
        }
    }

    @Test("Missing provenance is rejected — provenance is explicit")
    func missingProvenanceRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let bad = validResult(provenance: [])
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try attachJSON(bad))
        }
    }

    @Test("Canonical provenance references are workspace-gated")
    func provenanceGated() async throws {
        let deniedID = UUID()
        let (executor, rig, stateJSON) = try await rigAndState(
            gate: FixtureEvidenceGate(deniedIDs: [deniedID]))
        let bad = validResult(provenance: [WorkflowMethodProvenanceReference(
            objectKind: "claim", canonicalObjectID: deniedID.uuidString)])
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try attachJSON(bad))
        }
    }

    @Test("Completion without a result is blocked")
    func completionWithoutResultBlocked() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let complete = try WorkflowStepPayloadCodec.encode(MethodStepCommand.complete)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: complete)
        }
    }

    @Test("A valid attached result emits a satisfied method fact; completion advances")
    func validResultEmitsSatisfiedFact() async throws {
        let (executor, rig, prepJSON) = try await rigAndState(reqs: [methodReq()])
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try attachJSON(validResult()))
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: r1.stateJSON)
        #expect(header.requirementFacts[0].isSatisfied == true)

        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let complete = try WorkflowStepPayloadCodec.encode(MethodStepCommand.complete)
        let r2 = try await executor.execute(context: ctx2, commandJSON: complete)
        #expect(r2.disposition == .advance(.label("next")))
    }

    @Test("Removing the result flips the method fact back to unsatisfied")
    func removedResultUnsatisfiedFact() async throws {
        let (executor, rig, prepJSON) = try await rigAndState(reqs: [methodReq()])
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try attachJSON(validResult()))
        let remove = try WorkflowStepPayloadCodec.encode(MethodStepCommand.removeResult)
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: remove)
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: r2.stateJSON)
        #expect(header.requirementFacts[0].isSatisfied == false)
        let state = try decodeEnvelopeState(MethodStepState.self, from: r2.stateJSON)
        #expect(state.status == .awaitingResult)
    }

    @Test("A method result never claims to be a confirmed fact or root cause")
    func resultIsAdapterOnlyReference() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(context: ctx, commandJSON: try attachJSON(validResult()))
        // The serialized state carries reference fields only — no claim/root-cause/
        // confirmation vocabulary exists anywhere in the state envelope.
        let lowered = r.stateJSON.lowercased()
        #expect(!lowered.contains("confirmedfact"))
        #expect(!lowered.contains("rootcause"))
        #expect(!lowered.contains("\"claimid\""))
        #expect(r.outputJSON == nil)
    }

    @Test("Requirement facts use the DECLARED requirement ID, never derived from detail")
    func factsUseDeclaredRequirementID() async throws {
        let (executor, rig, prepJSON) = try await rigAndState(
            reqs: [methodReq(id: "req.custom.method-check")])
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r = try await executor.execute(context: ctx, commandJSON: try attachJSON(validResult()))
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: r.stateJSON)
        #expect(header.requirementFacts.map(\.requirementID) == ["req.custom.method-check"])
    }
}
