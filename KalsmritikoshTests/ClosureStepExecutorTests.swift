//
//  ClosureStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — ClosureStepExecutor: human-confirmed closure, checklist and
//  blocking-attention gates, declared return edges, no history deletion. 12 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — ClosureStepExecutor")
@MainActor
struct ClosureStepExecutorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_600_000)

    private func humanActor(_ id: String = "owner-1") -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: nil)
    }

    private func rigAndState() async throws -> (ClosureStepExecutor, ExecutorTestRig, String) {
        let executor = ClosureStepExecutor()
        let rig = try makeExecutorTestRig(kind: .closure)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func summarized(
        executor: ClosureStepExecutor, rig: ExecutorTestRig, prepJSON: String,
        summary: String = "All findings reviewed; memo delivered"
    ) async throws -> String {
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(ClosureStepCommand.setSummary(summary))
        return try await executor.execute(context: ctx, commandJSON: cmd).stateJSON
    }

    private func confirmJSON(rationale: String? = "done") throws -> String {
        try WorkflowStepPayloadCodec.encode(ClosureStepCommand.confirmClosure(rationale: rationale))
    }

    private func openBlockingItem() -> WorkflowAttentionItem {
        WorkflowAttentionItem(
            id: UUID(), workflowRunID: UUID(), stepRunID: nil,
            sourceKind: .requirement, sourceID: "req.x",
            severity: .blocking, status: .open,
            title: "Unmet requirement", detail: nil,
            createdAt: t0, resolvedAt: nil, resolvedBy: nil, resolutionNote: nil)
    }

    @Test("Closure requires an identified human — system actors cannot close")
    func systemCannotClose() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state, actor: .system)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try confirmJSON())
        }
    }

    @Test("Deterministic rules cannot close")
    func ruleCannotClose() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let rule = WorkflowLifecycleActor(kind: .deterministicRule, identifier: "auto", role: nil)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state, actor: rule)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try confirmJSON())
        }
    }

    @Test("A blank summary blocks closure")
    func summaryRequired() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try confirmJSON())
        }
    }

    @Test("An unsatisfied checklist item blocks closure; satisfying it unblocks")
    func checklistEnforced() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        var state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let unsatisfied = WorkflowClosureChecklistItem(
            id: "check.receipts", label: "Receipts archived", isSatisfied: false)
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state)
        state = try await executor.execute(
            context: ctx1,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                ClosureStepCommand.setChecklistItem(unsatisfied))).stateJSON

        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor())
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: try confirmJSON())
        }

        let satisfied = WorkflowClosureChecklistItem(
            id: "check.receipts", label: "Receipts archived", isSatisfied: true)
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state)
        state = try await executor.execute(
            context: ctx3,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                ClosureStepCommand.setChecklistItem(satisfied))).stateJSON
        let ctx4 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor())
        let r = try await executor.execute(context: ctx4, commandJSON: try confirmJSON())
        #expect(r.disposition == .completeTerminal)
    }

    @Test("An open blocking attention item prevents closure")
    func openBlockingAttentionPreventsClosure() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor(),
            attentionItems: [openBlockingItem()])
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try confirmJSON())
        }
    }

    @Test("Human closure emits completeTerminal with the decision recorded in state")
    func humanClosureEmitsCompleteTerminal() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor("case-owner"))
        let r = try await executor.execute(context: ctx, commandJSON: try confirmJSON(rationale: "complete"))
        #expect(r.disposition == .completeTerminal)
        let decoded = try decodeEnvelopeState(ClosureStepState.self, from: r.stateJSON)
        #expect(decoded.decision == .close)
        #expect(decoded.decidedBy == "case-owner")
        #expect(decoded.rationale == "complete")
    }

    @Test("Return-for-more-work requires a declared return edge")
    func returnRequiresDeclaredEdge() async throws {
        // The default rig declares NO return transition.
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor())
        let cmd = try WorkflowStepPayloadCodec.encode(
            ClosureStepCommand.returnForMoreWork(selector: .label("rework"), rationale: nil))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Return-for-more-work uses the declared return edge")
    func returnUsesDeclaredEdge() async throws {
        // Custom rig: closure step with a forward edge AND a declared return edge.
        let workID = StepDefinitionID(rawValue: "step.work.ret")
        let closureID = StepDefinitionID(rawValue: "step.closure.ret")
        let doneID = StepDefinitionID(rawValue: "step.done.ret")
        let work = PersonaWorkflowStepDefinition(
            id: workID, kind: .intake, label: "Work", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: closureID)])
        let closure = PersonaWorkflowStepDefinition(
            id: closureID, kind: .closure, label: "Close",
            transitions: [
                WorkflowTransitionDefinition(label: "finish", targetStepID: doneID),
                WorkflowTransitionDefinition(label: "rework", targetStepID: workID, isReturn: true)
            ],
            loopPolicy: .returnsToStep)
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let wfID = WorkflowDefinitionID(rawValue: "com.closure.ret.wf")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Ret WF", steps: [work, closure, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let appID = ApplicationDefinitionID(rawValue: "com.closure.ret.app")
        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.closure.ret.term"),
            version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "Ret App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: term.id, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        let contract = try WorkflowRunContractSnapshot(from: pkg, selectedWorkflowID: wfID)
        let reconstructed = try #require(contract.reconstructDefinition())
        let closureStep = try #require(
            reconstructed.definition.steps.first(where: { $0.id == closureID }))
        let rig = ExecutorTestRig(
            validated: reconstructed, entryStep: closureStep, contract: contract)

        let executor = ClosureStepExecutor()
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prep.stateJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor("case-owner"))
        let cmd = try WorkflowStepPayloadCodec.encode(
            ClosureStepCommand.returnForMoreWork(selector: .label("rework"), rationale: "gaps found"))
        let r = try await executor.execute(context: ctx, commandJSON: cmd)
        #expect(r.disposition == .returnToPriorStep(.label("rework")))
        let decoded = try decodeEnvelopeState(ClosureStepState.self, from: r.stateJSON)
        #expect(decoded.decision == .returnForMoreWork)
    }

    @Test("Return-for-more-work also requires a human actor")
    func returnRequiresHuman() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state, actor: .system)
        let cmd = try WorkflowStepPayloadCodec.encode(
            ClosureStepCommand.returnForMoreWork(selector: .label("rework"), rationale: nil))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Limitations are add/remove-only workflow state")
    func limitationsAddRemove() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let s1 = try await executor.execute(
            context: ctx1,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                ClosureStepCommand.addLimitation("Single-source areas remain"))).stateJSON
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: s1)
        let s2 = try await executor.execute(
            context: ctx2,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                ClosureStepCommand.removeLimitation("Single-source areas remain"))).stateJSON
        let state = try decodeEnvelopeState(ClosureStepState.self, from: s2)
        #expect(state.knownLimitations.isEmpty)
    }

    @Test("A blank limitation is rejected")
    func blankLimitationRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(ClosureStepCommand.addLimitation("  "))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Closure state hashes under the stored-byte contract")
    func closureStateHashContract() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await summarized(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor())
        let r = try await executor.execute(context: ctx, commandJSON: try confirmJSON())
        #expect(r.stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: r.stateJSON))
    }
}
