//
//  FormStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — FormStepExecutor: requirement facts, field commands, blocking completion guard.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — FormStepExecutor")
struct FormStepExecutorTests {

    private let executor = FormStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.form")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .form)
    }

    // MARK: - prepare()

    @Test("prepare() creates unsatisfied facts for formFieldCompleted requirements")
    func prepareCreatesFacts() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.name", kind: .formFieldCompleted, label: "Name", isBlocking: true)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: result.stateJSON)
        #expect(header.requirementFacts.count == 1)
        #expect(header.requirementFacts.first?.requirementID == "req.name")
        #expect(header.requirementFacts.first?.isSatisfied == false)
    }

    @Test("prepare() with no requirements creates no facts")
    func prepareNoFacts() async throws {
        let rig = try makeExecutorTestRig(kind: .form)
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: result.stateJSON)
        #expect(header.requirementFacts.isEmpty)
    }

    // MARK: - setField

    @Test("setField marks corresponding formFieldCompleted requirement as satisfied")
    func setFieldSatisfiesFact() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.name", kind: .formFieldCompleted, label: "Name", isBlocking: true)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(
            FormStepCommand.setField(id: "req.name", value: .text("Alice")))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: result.stateJSON)
        #expect(header.requirementFacts.first?.isSatisfied == true)
    }

    // MARK: - clearField

    @Test("clearField marks requirement as unsatisfied")
    func clearFieldUnsatisfies() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.age", kind: .formFieldCompleted, label: "Age", isBlocking: false)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCmd = try WorkflowStepPayloadCodec.encode(
            FormStepCommand.setField(id: "req.age", value: .number(30)))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCmd)
        let clearCmd = try WorkflowStepPayloadCodec.encode(FormStepCommand.clearField(id: "req.age"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: clearCmd)
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: r2.stateJSON)
        #expect(header.requirementFacts.first(where: { $0.requirementID == "req.age" })?.isSatisfied == false)
    }

    // MARK: - complete

    @Test("complete with all blocking requirements satisfied returns advance")
    func completeAllBlockingMet() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.email", kind: .formFieldCompleted, label: "Email", isBlocking: true)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCmd = try WorkflowStepPayloadCodec.encode(
            FormStepCommand.setField(id: "req.email", value: .text("a@b.com")))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCmd)
        let completeCmd = try WorkflowStepPayloadCodec.encode(FormStepCommand.complete)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let result = try await executor.execute(context: ec2, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\"))")
        }
    }

    @Test("complete with missing blocking requirement throws completionNotReady")
    func completeMissingBlockingFails() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.email", kind: .formFieldCompleted, label: "Email", isBlocking: true)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(FormStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: cmd)
        }
    }

    @Test("complete with non-blocking requirement missing still advances")
    func completeNonBlockingOptional() async throws {
        let req = PersonaWorkflowRequirement(
            id: "req.notes", kind: .formFieldCompleted, label: "Notes", isBlocking: false)
        let rig = try makeExecutorTestRig(kind: .form, reqs: [req])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(FormStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        #expect(result.disposition != .remainActive)
    }

    // MARK: - value types

    @Test("WorkflowFormValue.boolean roundtrips through encode/decode")
    func booleanValueRoundtrip() throws {
        let json = try WorkflowStepPayloadCodec.encode(WorkflowFormValue.boolean(true))
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowFormValue.self, from: json)
        #expect(decoded == .boolean(true))
    }

    @Test("WorkflowFormValue.multiSelection roundtrips through encode/decode")
    func multiSelectionRoundtrip() throws {
        let json = try WorkflowStepPayloadCodec.encode(WorkflowFormValue.multiSelection(["a", "b"]))
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowFormValue.self, from: json)
        #expect(decoded == .multiSelection(["a", "b"]))
    }

    @Test("WorkflowFormValue.number roundtrips through encode/decode")
    func numberValueRoundtrip() throws {
        let json = try WorkflowStepPayloadCodec.encode(WorkflowFormValue.number(3.14))
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowFormValue.self, from: json)
        #expect(decoded == .number(3.14))
    }
}
