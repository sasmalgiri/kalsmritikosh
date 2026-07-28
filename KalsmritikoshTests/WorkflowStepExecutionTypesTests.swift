//
//  WorkflowStepExecutionTypesTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — Foundation types: IDs, bindings, contexts, results, dispositions, errors.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepExecutionTypes")
struct WorkflowStepExecutionTypesTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    // MARK: - ID types

    @Test("WorkflowStepExecutorID preserves rawValue")
    func executorIDRawValue() {
        let id = WorkflowStepExecutorID(rawValue: "com.test.step.foo")
        #expect(id.rawValue == "com.test.step.foo")
    }

    @Test("WorkflowStepExecutorVersion preserves rawValue")
    func executorVersionRawValue() {
        let v = WorkflowStepExecutorVersion(rawValue: "2.1")
        #expect(v.rawValue == "2.1")
    }

    @Test("WorkflowStepExecutorID is hashable and equatable")
    func executorIDHashEquality() {
        let a = WorkflowStepExecutorID(rawValue: "com.test.x")
        let b = WorkflowStepExecutorID(rawValue: "com.test.x")
        let c = WorkflowStepExecutorID(rawValue: "com.test.y")
        #expect(a == b)
        #expect(a != c)
        var s = Set<WorkflowStepExecutorID>()
        s.insert(a); s.insert(b)
        #expect(s.count == 1)
    }

    // MARK: - Binding

    @Test("WorkflowStepExecutorBinding preserves all fields")
    func bindingFields() {
        let id = WorkflowStepExecutorID(rawValue: "com.test.step.intake")
        let ver = WorkflowStepExecutorVersion(rawValue: "1.0")
        let binding = WorkflowStepExecutorBinding(
            workflowSchemaVersion: 3,
            stepKind: .intake,
            executorID: id,
            executorVersion: ver
        )
        #expect(binding.workflowSchemaVersion == 3)
        #expect(binding.stepKind == .intake)
        #expect(binding.executorID == id)
        #expect(binding.executorVersion == ver)
    }

    // MARK: - PreparationResult

    @Test("WorkflowStepPreparationResult preserves fields")
    func preparationResultFields() {
        let id = WorkflowStepExecutorID(rawValue: "com.test.a")
        let ver = WorkflowStepExecutorVersion(rawValue: "1.0")
        let r = WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: "{\"x\":1}",
            stateSHA256: "abc123",
            executorID: id, executorVersion: ver
        )
        #expect(r.inputJSON == "{}")
        #expect(r.stateJSON == "{\"x\":1}")
        #expect(r.stateSHA256 == "abc123")
        #expect(r.executorID == id)
        #expect(r.executorVersion == ver)
    }

    // MARK: - Disposition

    @Test("WorkflowStepExecutionDisposition.remainActive equates to itself")
    func dispositionRemainActive() {
        #expect(WorkflowStepExecutionDisposition.remainActive == .remainActive)
    }

    @Test("WorkflowStepExecutionDisposition.advance equality uses selector")
    func dispositionAdvanceEquality() {
        let s1 = WorkflowTransitionSelector.label("next")
        let s2 = WorkflowTransitionSelector.label("next")
        let s3 = WorkflowTransitionSelector.label("other")
        #expect(WorkflowStepExecutionDisposition.advance(s1) == .advance(s2))
        #expect(WorkflowStepExecutionDisposition.advance(s1) != .advance(s3))
    }

    @Test("WorkflowStepExecutionDisposition.completeTerminal equates to itself")
    func dispositionCompleteTerminal() {
        #expect(WorkflowStepExecutionDisposition.completeTerminal == .completeTerminal)
    }

    // MARK: - ExecutionResult

    @Test("WorkflowStepExecutionResult preserves all fields")
    func executionResultFields() {
        let r = WorkflowStepExecutionResult(
            stateJSON: "{\"a\":1}",
            stateSHA256: "sha",
            outputJSON: "{\"out\":true}",
            disposition: .remainActive,
            detail: "saved"
        )
        #expect(r.stateJSON == "{\"a\":1}")
        #expect(r.stateSHA256 == "sha")
        #expect(r.outputJSON == "{\"out\":true}")
        #expect(r.disposition == .remainActive)
        #expect(r.detail == "saved")
    }

    // MARK: - Error vocabulary

    @Test("WorkflowStepExecutionError.malformedCommandJSON equates to itself")
    func errorEquality() {
        let e1 = WorkflowStepExecutionError.malformedCommandJSON
        let e2 = WorkflowStepExecutionError.malformedCommandJSON
        #expect(e1 == e2)
    }

    @Test("WorkflowStepExecutionError.executorKindMismatch preserves payload")
    func errorKindMismatch() {
        let id = WorkflowStepExecutorID(rawValue: "com.test")
        let err = WorkflowStepExecutionError.executorKindMismatch(
            executor: id, expected: .intake, actual: .scope)
        if case .executorKindMismatch(let execID, let exp, let act) = err {
            #expect(execID == id)
            #expect(exp == .intake)
            #expect(act == .scope)
        } else {
            Issue.record("Wrong error case")
        }
    }
}
