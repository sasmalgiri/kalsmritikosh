//
//  WorkflowLifecycleDefinitionValidatorTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — WorkflowLifecycleDefinitionValidator: lifecycle-specific structural checks.
//  20 tests covering terminal/non-terminal transitions, closure kind, blank/duplicate
//  transition labels, duplicate targets, decision branch alignment, conditions,
//  human-approval constraints, and return transition policies.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleDefinitionValidator")
struct WorkflowLifecycleDefinitionValidatorTests {

    private let validator = WorkflowLifecycleDefinitionValidator()

    // MARK: - Helpers

    private func compile(_ def: PersonaWorkflowDefinition) throws -> ValidatedWorkflowDefinition {
        try WorkflowDefinitionCompiler().compile(def)
    }

    private func twoStepDef(
        entryStep: PersonaWorkflowStepDefinition,
        terminalStep: PersonaWorkflowStepDefinition,
        id: String = "wf.test"
    ) -> PersonaWorkflowDefinition {
        PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: id), version: 1, schemaVersion: 1,
            label: "Test", steps: [entryStep, terminalStep])
    }

    private func minimalEntry(
        id: String = "step.entry",
        transitions: [WorkflowTransitionDefinition] = []
    ) -> PersonaWorkflowStepDefinition {
        PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: id), kind: .intake, label: "Entry",
            isEntry: true, transitions: transitions)
    }

    private func minimalTerminal(id: String = "step.done") -> PersonaWorkflowStepDefinition {
        PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: id), kind: .closure, label: "Done", isTerminal: true)
    }

    private func nextTransition(to targetID: String = "step.done") -> WorkflowTransitionDefinition {
        WorkflowTransitionDefinition(label: "next", targetStepID: StepDefinitionID(rawValue: targetID))
    }

    // MARK: - 1: Valid minimal definition passes

    @Test("Valid two-step definition passes validator")
    func validMinimalDefinitionPasses() throws {
        let def = twoStepDef(
            entryStep: minimalEntry(transitions: [nextTransition()]),
            terminalStep: minimalTerminal()
        )
        let validated = try compile(def)
        #expect(throws: Never.self) { try validator.validate(validated) }
    }

    // MARK: - 2: Terminal step with transitions

    @Test("Terminal step with transitions throws terminalStepHasTransitions")
    func terminalStepWithTransitionsThrows() throws {
        let terminal = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.done"), kind: .closure, label: "Done",
            isTerminal: true,
            transitions: [WorkflowTransitionDefinition(
                label: "extra", targetStepID: StepDefinitionID(rawValue: "step.entry"))])
        // Compiler won't fail (terminal step can have transitions in the definition layer)
        // We force-construct ValidatedWorkflowDefinition to test the lifecycle validator
        let entry = minimalEntry(transitions: [nextTransition()])
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw,
            entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")]
        )
        do {
            try validator.validate(validated)
            Issue.record("Expected terminalStepHasTransitions")
        } catch WorkflowLifecycleError.terminalStepHasTransitions(let sid) {
            #expect(sid.rawValue == "step.done")
        }
    }

    // MARK: - 3: Non-terminal step with no transitions

    @Test("Non-terminal step with no transitions throws nonterminalStepHasNoTransitions")
    func nonterminalStepWithNoTransitionsThrows() throws {
        let entry = minimalEntry(transitions: [])  // no transitions
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw,
            entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")]
        )
        do {
            try validator.validate(validated)
            Issue.record("Expected nonterminalStepHasNoTransitions")
        } catch WorkflowLifecycleError.nonterminalStepHasNoTransitions(let sid) {
            #expect(sid.rawValue == "step.entry")
        }
    }

    // MARK: - 4: Closure step not terminal

    @Test("Closure kind step that is not terminal throws closureStepNotTerminal")
    func closureNotTerminalThrows() throws {
        let closureStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.close"), kind: .closure, label: "Close",
            isTerminal: false,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))])
        let terminal = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.done"), kind: .form, label: "Done",
            isTerminal: true)
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.close"))])
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, closureStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw,
            entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"),
                               StepDefinitionID(rawValue: "step.close"),
                               StepDefinitionID(rawValue: "step.done")]
        )
        do {
            try validator.validate(validated)
            Issue.record("Expected closureStepNotTerminal")
        } catch WorkflowLifecycleError.closureStepNotTerminal(let sid) {
            #expect(sid.rawValue == "step.close")
        }
    }

    // MARK: - 5: Blank transition label

    @Test("Blank transition label throws blankTransitionLabel")
    func blankTransitionLabelThrows() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "   ", targetStepID: StepDefinitionID(rawValue: "step.done"))])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw,
            entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")]
        )
        do {
            try validator.validate(validated)
            Issue.record("Expected blankTransitionLabel")
        } catch WorkflowLifecycleError.blankTransitionLabel(let sid) {
            #expect(sid.rawValue == "step.entry")
        }
    }

    // MARK: - 6: Duplicate transition label

    @Test("Duplicate transition label throws duplicateTransitionLabel")
    func duplicateTransitionLabelThrows() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "next", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))
            ])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected duplicateTransitionLabel")
        } catch WorkflowLifecycleError.duplicateTransitionLabel(let sid, let label) {
            #expect(sid.rawValue == "step.entry")
            #expect(label == "next")
        }
    }

    // MARK: - 7: Duplicate transition target

    @Test("Two different-label transitions to same target throws duplicateTransitionTarget")
    func duplicateTransitionTargetThrows() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "a", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(label: "b", targetStepID: StepDefinitionID(rawValue: "step.done"))
            ])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected duplicateTransitionTarget")
        } catch WorkflowLifecycleError.duplicateTransitionTarget(let sid, let targetID) {
            #expect(sid.rawValue == "step.entry")
            #expect(targetID.rawValue == "step.done")
        }
    }

    // MARK: - 8: Decision step branch-transition alignment

    @Test("Decision step with missing transition for branch throws decisionBranchTransitionMismatch")
    func decisionBranchTransitionMismatchThrows() throws {
        let decStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.dec"), kind: .decision, label: "Dec",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "yes", targetStepID: StepDefinitionID(rawValue: "step.done"))],
            decisionBranches: ["yes", "no"])  // "no" has no matching transition
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [decStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.dec"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.dec"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected decisionBranchTransitionMismatch")
        } catch WorkflowLifecycleError.decisionBranchTransitionMismatch(let sid, let branch) {
            #expect(sid.rawValue == "step.dec")
            #expect(branch == "no")
        }
    }

    // MARK: - 9: Decision step branch with condition

    @Test("Decision step forward transition with condition throws decisionBranchWithCondition")
    func decisionBranchWithConditionThrows() throws {
        let decStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.dec"), kind: .decision, label: "Dec",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "yes", targetStepID: StepDefinitionID(rawValue: "step.done"),
                condition: "someCondition")],
            decisionBranches: ["yes"])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [decStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.dec"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.dec"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected decisionBranchWithCondition")
        } catch WorkflowLifecycleError.decisionBranchWithCondition(let sid) {
            #expect(sid.rawValue == "step.dec")
        }
    }

    // MARK: - 10: humanApproval blank role

    @Test("humanApproval step with blank role throws humanApprovalBlankRole")
    func humanApprovalBlankRoleThrows() throws {
        let approvalStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.approve"), kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [nextTransition()],
            approverRoles: ["  "])  // blank
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [approvalStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.approve"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.approve"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected humanApprovalBlankRole")
        } catch WorkflowLifecycleError.humanApprovalBlankRole(let sid) {
            #expect(sid.rawValue == "step.approve")
        }
    }

    // MARK: - 11: humanApproval duplicate role

    @Test("humanApproval step with duplicate role throws humanApprovalDuplicateRole")
    func humanApprovalDuplicateRoleThrows() throws {
        let approvalStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.approve"), kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [nextTransition()],
            approverRoles: ["supervisor", "supervisor"])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [approvalStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.approve"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.approve"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected humanApprovalDuplicateRole")
        } catch WorkflowLifecycleError.humanApprovalDuplicateRole(let sid, let role) {
            #expect(sid.rawValue == "step.approve")
            #expect(role == "supervisor")
        }
    }

    // MARK: - 12: humanApproval conditioned transition

    @Test("humanApproval step with conditioned forward transition throws humanApprovalConditionedTransition")
    func humanApprovalConditionedTransitionThrows() throws {
        let approvalStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.approve"), kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"),
                condition: "approved")],
            approverRoles: ["supervisor"])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [approvalStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.approve"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.approve"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected humanApprovalConditionedTransition")
        } catch WorkflowLifecycleError.humanApprovalConditionedTransition(let sid) {
            #expect(sid.rawValue == "step.approve")
        }
    }

    // MARK: - 13: Return transition without loopPolicy

    @Test("Return transition without loopPolicy throws returnTransitionMissingLoopPolicy")
    func returnTransitionWithoutLoopPolicyThrows() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [nextTransition()])
        let middleStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.middle"), kind: .form, label: "Middle",
            transitions: [
                nextTransition(),
                WorkflowTransitionDefinition(
                    label: "back", targetStepID: StepDefinitionID(rawValue: "step.entry"),
                    isReturn: true)
            ],
            loopPolicy: nil)  // missing loopPolicy
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [entry, middleStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"),
                               StepDefinitionID(rawValue: "step.middle"),
                               StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected returnTransitionMissingLoopPolicy")
        } catch WorkflowLifecycleError.returnTransitionMissingLoopPolicy(let sid) {
            #expect(sid.rawValue == "step.middle")
        }
    }

    // MARK: - 14: returnsToStep targets later step

    @Test("returnsToStep returning to a later step throws returnTransitionToLaterStep")
    func returnTransitionToLaterStepThrows() throws {
        // entry(0) → middle(1) → done(2); middle returns to done which is LATER
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.middle"))])
        let middleStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.middle"), kind: .form, label: "Middle",
            transitions: [
                WorkflowTransitionDefinition(
                    label: "forward", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(
                    label: "back", targetStepID: StepDefinitionID(rawValue: "step.done"),
                    isReturn: true)
            ],
            loopPolicy: .returnsToStep)
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [entry, middleStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"),
                               StepDefinitionID(rawValue: "step.middle"),
                               StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected returnTransitionToLaterStep")
        } catch WorkflowLifecycleError.returnTransitionToLaterStep(let sid, let targetSid) {
            #expect(sid.rawValue == "step.middle")
            _ = targetSid
        }
    }

    // MARK: - 15: iterates must be self-loop

    @Test("iterates return transition targeting a different step throws invalidSelfReturn")
    func iteratesMustBeSelfLoopThrows() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))])
        let middleStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.middle"), kind: .form, label: "Middle",
            transitions: [
                WorkflowTransitionDefinition(
                    label: "forward", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(
                    label: "back", targetStepID: StepDefinitionID(rawValue: "step.entry"),
                    isReturn: true)
            ],
            loopPolicy: .iterates)  // iterates but targeting different step
        let terminal = minimalTerminal()
        // Manually construct ValidatedWorkflowDefinition with middle step
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [entry, middleStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"),
                               StepDefinitionID(rawValue: "step.middle"),
                               StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected invalidSelfReturn")
        } catch WorkflowLifecycleError.invalidSelfReturn(let sid) {
            #expect(sid.rawValue == "step.middle")
        }
    }

    // MARK: - 16: Valid decision step passes

    @Test("Valid decision step with aligned branches passes validator")
    func validDecisionStepPasses() throws {
        let decStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.dec"), kind: .decision, label: "Dec",
            isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "yes", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(label: "no", targetStepID: StepDefinitionID(rawValue: "step.done"))
            ],
            decisionBranches: ["yes", "no"])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [decStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.dec"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.dec"), StepDefinitionID(rawValue: "step.done")])
        #expect(throws: Never.self) { try validator.validate(validated) }
    }

    // MARK: - 17: Valid humanApproval step passes

    @Test("Valid humanApproval step with unique non-blank roles passes validator")
    func validHumanApprovalPasses() throws {
        let approvalStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.approve"), kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [nextTransition()],
            approverRoles: ["supervisor", "director"])
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [approvalStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.approve"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.approve"), StepDefinitionID(rawValue: "step.done")])
        #expect(throws: Never.self) { try validator.validate(validated) }
    }

    // MARK: - 18: Valid returnsToStep passes

    @Test("Valid returnsToStep return transition targeting earlier step passes")
    func validReturnsToStepPasses() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.middle"))])
        let middleStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.middle"), kind: .form, label: "Middle",
            transitions: [
                WorkflowTransitionDefinition(label: "forward", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(
                    label: "back", targetStepID: StepDefinitionID(rawValue: "step.entry"),
                    isReturn: true)
            ],
            loopPolicy: .returnsToStep)
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [entry, middleStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"),
                               StepDefinitionID(rawValue: "step.middle"),
                               StepDefinitionID(rawValue: "step.done")])
        #expect(throws: Never.self) { try validator.validate(validated) }
    }

    // MARK: - 19: Valid iterates self-loop passes

    @Test("Valid iterates self-loop transition passes validator")
    func validIteratesSelfLoopPasses() throws {
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"), kind: .intake, label: "Entry",
            isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "next", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(
                    label: "retry", targetStepID: StepDefinitionID(rawValue: "step.entry"),
                    isReturn: true)
            ],
            loopPolicy: .iterates)
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1, label: "T",
            steps: [entry, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.entry"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.entry"), StepDefinitionID(rawValue: "step.done")])
        #expect(throws: Never.self) { try validator.validate(validated) }
    }

    // MARK: - 20: Undeclared decision branch

    @Test("Decision step forward transition label not in decisionBranches throws undeclaredDecisionBranch")
    func undeclaredDecisionBranchThrows() throws {
        let decStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.dec"), kind: .decision, label: "Dec",
            isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "yes", targetStepID: StepDefinitionID(rawValue: "step.done")),
                WorkflowTransitionDefinition(label: "maybe", targetStepID: StepDefinitionID(rawValue: "step.done"))
            ],
            decisionBranches: ["yes"])  // "maybe" not declared
        let terminal = minimalTerminal()
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf"), version: 1, schemaVersion: 1,
            label: "T", steps: [decStep, terminal])
        let validated = ValidatedWorkflowDefinition(
            definition: raw, entryStepID: StepDefinitionID(rawValue: "step.dec"),
            terminalStepIDs: [StepDefinitionID(rawValue: "step.done")],
            reachableStepIDs: [StepDefinitionID(rawValue: "step.dec"), StepDefinitionID(rawValue: "step.done")])
        do {
            try validator.validate(validated)
            Issue.record("Expected undeclaredDecisionBranch")
        } catch WorkflowLifecycleError.undeclaredDecisionBranch(let sid, let branch) {
            #expect(sid.rawValue == "step.dec")
            #expect(branch == "maybe")
        }
    }
}
