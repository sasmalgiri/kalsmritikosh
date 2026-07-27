//
//  WorkflowDefinitionCompilerTests.swift
//  KalsmritikoshTests
//
//  PJE-001 — WorkflowDefinitionCompiler validation. Locks:
//    1.  A single entry+terminal step compiles successfully.
//    2.  A linear three-step workflow compiles with correct entry and terminal IDs.
//    3.  An explicit isReturn transition is accepted (no undeclared cycle error).
//    4.  The same definition always compiles to the same result (idempotent).
//    5.  Duplicate step IDs are rejected.
//    6.  A workflow with no entry step is rejected.
//    7.  A workflow with more than one entry step is rejected.
//    8.  A transition targeting an unknown step ID is rejected.
//    9.  A step unreachable from the entry step is rejected.
//   10.  A workflow with no reachable terminal step is rejected.
//   11.  An undeclared cycle (no isReturn flag) is rejected.
//   12.  A decision step with no declared branches is rejected.
//   13.  A humanApproval step with no approver role is rejected.
//   14.  A workProductBuild step with no artifact template ID is rejected.
//   15.  A closure step with a blocking validation but no validationPassed requirement is rejected.
//   16.  A closure step that correctly pairs a blocking validation with a blocking
//        validationPassed requirement compiles successfully.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-001 — WorkflowDefinitionCompiler")
struct WorkflowDefinitionCompilerTests {

    private let compiler = WorkflowDefinitionCompiler()
    private let wfID     = WorkflowDefinitionID(rawValue: "com.test.workflow")

    // MARK: - Shared builders

    private func step(
        _ rawID: String,
        kind: WorkflowStepKind = .form,
        isEntry: Bool = false,
        isTerminal: Bool = false,
        transitions: [WorkflowTransitionDefinition] = [],
        requirements: [PersonaWorkflowRequirement] = [],
        validations: [PersonaWorkflowValidation] = [],
        artifacts: [PersonaWorkflowArtifactDefinition] = [],
        decisionBranches: [String] = [],
        approverRoles: [String] = [],
        loopPolicy: WorkflowLoopPolicy? = nil
    ) -> PersonaWorkflowStepDefinition {
        PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: rawID),
            kind: kind,
            label: rawID,
            isEntry: isEntry,
            isTerminal: isTerminal,
            transitions: transitions,
            requirements: requirements,
            validations: validations,
            artifacts: artifacts,
            decisionBranches: decisionBranches,
            approverRoles: approverRoles,
            loopPolicy: loopPolicy
        )
    }

    private func to(_ rawID: String, isReturn: Bool = false) -> WorkflowTransitionDefinition {
        WorkflowTransitionDefinition(
            label: rawID,
            targetStepID: StepDefinitionID(rawValue: rawID),
            isReturn: isReturn
        )
    }

    private func workflow(_ steps: PersonaWorkflowStepDefinition...) -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Test", steps: steps)
    }

    private func sid(_ rawID: String) -> StepDefinitionID {
        StepDefinitionID(rawValue: rawID)
    }

    // MARK: - Case 1: single entry+terminal step

    @Test("A single entry+terminal step workflow compiles successfully")
    func validSingleStepWorkflowCompiles() throws {
        let result = try compiler.compile(
            workflow(step("start", kind: .intake, isEntry: true, isTerminal: true))
        )
        #expect(result.entryStepID == sid("start"))
        #expect(result.terminalStepIDs == [sid("start")])
        #expect(result.reachableStepIDs == [sid("start")])
    }

    // MARK: - Case 2: valid linear three-step workflow

    @Test("A linear three-step workflow compiles with correct entry and terminal IDs")
    func validLinearWorkflowCompiles() throws {
        let result = try compiler.compile(workflow(
            step("a", kind: .intake,   isEntry: true, transitions: [to("b")]),
            step("b", kind: .form,                    transitions: [to("c")]),
            step("c", kind: .closure,  isTerminal: true)
        ))
        #expect(result.entryStepID == sid("a"))
        #expect(result.terminalStepIDs == [sid("c")])
        #expect(result.reachableStepIDs.count == 3)
    }

    // MARK: - Case 3: explicit return transition accepted

    @Test("An isReturn=true transition from b back to a is accepted without a cycle error")
    func validReturnTransitionCompiles() throws {
        let result = try compiler.compile(workflow(
            step("a", kind: .intake, isEntry: true,
                 transitions: [to("b")]),
            step("b", kind: .reviewEvidence, loopPolicy: .returnsToStep,
                 transitions: [to("a", isReturn: true), to("c")]),
            step("c", kind: .closure, isTerminal: true)
        ))
        #expect(result.entryStepID == sid("a"))
        #expect(result.terminalStepIDs.contains(sid("c")))
    }

    // MARK: - Case 4: idempotent compilation

    @Test("Compiling the same definition twice produces the same structural result")
    func validDefinitionIsIdempotent() throws {
        let definition = workflow(
            step("x", kind: .intake, isEntry: true, transitions: [to("y")]),
            step("y", kind: .closure, isTerminal: true)
        )
        let r1 = try compiler.compile(definition)
        let r2 = try compiler.compile(definition)
        #expect(r1.entryStepID == r2.entryStepID)
        #expect(r1.terminalStepIDs == r2.terminalStepIDs)
        #expect(r1.reachableStepIDs == r2.reachableStepIDs)
    }

    // MARK: - Case 5: duplicate step ID

    @Test("A duplicate step ID is rejected with duplicateStepID")
    func duplicateStepIDRejected() throws {
        let definition = workflow(
            step("dup", kind: .intake, isEntry: true, transitions: [to("end")]),
            step("dup", kind: .closure, isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.duplicateStepID(sid("dup"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 6: missing entry step

    @Test("A workflow with no entry step is rejected with missingEntryStep")
    func missingEntryStepRejected() throws {
        #expect(throws: WorkflowDefinitionError.missingEntryStep(wfID)) {
            try compiler.compile(workflow(
                step("only", kind: .closure, isTerminal: true)
            ))
        }
    }

    // MARK: - Case 7: multiple entry steps

    @Test("A workflow with two entry steps is rejected with multipleEntrySteps")
    func multipleEntryStepsRejected() throws {
        let definition = workflow(
            step("a", kind: .intake, isEntry: true, transitions: [to("c")]),
            step("b", kind: .intake, isEntry: true, transitions: [to("c")]),
            step("c", kind: .closure, isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.multipleEntrySteps([sid("a"), sid("b")])) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 8: unknown transition target

    @Test("A transition targeting an unknown step ID is rejected with unknownTransitionTarget")
    func unknownTransitionTargetRejected() throws {
        #expect(throws: WorkflowDefinitionError.unknownTransitionTarget(
            from: sid("start"), target: sid("ghost")
        )) {
            try compiler.compile(workflow(
                step("start", kind: .intake, isEntry: true, transitions: [to("ghost")])
            ))
        }
    }

    // MARK: - Case 9: unreachable step

    @Test("A step with no path from the entry step is rejected with unreachableStep")
    func unreachableStepRejected() throws {
        let definition = workflow(
            step("start", kind: .intake, isEntry: true, transitions: [to("end")]),
            step("end", kind: .closure, isTerminal: true),
            step("orphan", kind: .form)
        )
        #expect(throws: WorkflowDefinitionError.unreachableStep(sid("orphan"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 10: no terminal path

    @Test("A workflow with no reachable terminal step is rejected with noTerminalPath")
    func noTerminalPathRejected() throws {
        #expect(throws: WorkflowDefinitionError.noTerminalPath(wfID)) {
            try compiler.compile(workflow(
                step("start", kind: .intake, isEntry: true)
            ))
        }
    }

    // MARK: - Case 11: undeclared cycle

    @Test("A back edge without isReturn=true is rejected with undeclaredCycleInStep")
    func undeclaredCycleRejected() throws {
        // b → a is a back edge with no isReturn flag
        let definition = workflow(
            step("a", kind: .intake, isEntry: true, transitions: [to("b")]),
            step("b", kind: .form,   transitions: [to("a"), to("c")]),
            step("c", kind: .closure, isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.undeclaredCycleInStep(sid("b"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 12: decision step missing branches

    @Test("A decision step with no decisionBranches is rejected with decisionStepMissingBranches")
    func decisionStepMissingBranchesRejected() throws {
        let definition = workflow(
            step("start", kind: .intake,   isEntry: true, transitions: [to("decide")]),
            step("decide", kind: .decision, transitions: [to("end")]),
            step("end", kind: .closure,    isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.decisionStepMissingBranches(sid("decide"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 13: humanApproval step missing approver role

    @Test("A humanApproval step with no approverRoles is rejected with humanApprovalStepMissingApproverRequirement")
    func humanApprovalStepMissingApproverRoleRejected() throws {
        let definition = workflow(
            step("start",   kind: .intake,       isEntry: true, transitions: [to("approve")]),
            step("approve", kind: .humanApproval, transitions: [to("end")]),
            step("end",     kind: .closure,       isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.humanApprovalStepMissingApproverRequirement(sid("approve"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 14: workProductBuild step missing template

    @Test("A workProductBuild step whose artifacts all have nil workProductTemplateID is rejected")
    func workProductBuildStepMissingTemplateRejected() throws {
        let noTemplateArtifact = PersonaWorkflowArtifactDefinition(
            id: "a1", label: "Output", workProductTemplateID: nil, isRequired: true)
        let definition = workflow(
            step("start", kind: .intake,          isEntry: true, transitions: [to("build")]),
            step("build", kind: .workProductBuild, artifacts: [noTemplateArtifact],
                 transitions: [to("end")]),
            step("end",   kind: .closure,          isTerminal: true)
        )
        #expect(throws: WorkflowDefinitionError.workProductStepMissingTemplate(sid("build"))) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 15: closure step bypasses blocking validation

    @Test("A closure step with a blocking validation and no validationPassed requirement is rejected")
    func closureStepBypassesBlockingValidationRejected() throws {
        let blockingValidation = PersonaWorkflowValidation(
            id: "v1", validatorID: "quality.check", label: "Quality gate", isBlocking: true)
        let definition = workflow(
            step("start", kind: .intake, isEntry: true, transitions: [to("close")]),
            step("close", kind: .closure, isTerminal: true,
                 validations: [blockingValidation])
        )
        #expect(throws: WorkflowDefinitionError.closureStepBypassesRequiredValidation(
            sid("close"), validationID: "v1"
        )) {
            try compiler.compile(definition)
        }
    }

    // MARK: - Case 16: closure step with correct validationPassed requirement compiles

    @Test("A closure step that pairs a blocking validation with a blocking validationPassed requirement compiles")
    func closureStepWithValidationPassedRequirementCompiles() throws {
        let blockingValidation = PersonaWorkflowValidation(
            id: "v1", validatorID: "quality.check", label: "Quality gate", isBlocking: true)
        let passedRequirement = PersonaWorkflowRequirement(
            id: "r1", kind: .validationPassed, label: "Validation must pass", isBlocking: true)
        let result = try compiler.compile(workflow(
            step("start", kind: .intake, isEntry: true, transitions: [to("close")]),
            step("close", kind: .closure, isTerminal: true,
                 validations: [blockingValidation],
                 requirements: [passedRequirement])
        ))
        #expect(result.terminalStepIDs.contains(sid("close")))
    }
}
