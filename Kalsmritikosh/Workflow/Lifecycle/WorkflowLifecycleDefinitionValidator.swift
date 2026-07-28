//
//  WorkflowLifecycleDefinitionValidator.swift
//  Kalsmritikosh
//
//  PJE-004 — Lifecycle-specific additional checks on top of the PJE-001 compiler.
//  Adds lifecycle-specific policy checks:
//    • Terminal/non-terminal transition counts
//    • Closure step must be terminal
//    • Transition label uniqueness and non-blank
//    • Duplicate transition targets per step
//    • Decision branch ↔ transition alignment (no conditions on decision branches)
//    • Human-approval: approver roles non-blank, unique, no conditioned transitions
//    • Return transitions: must have loopPolicy; returnsToStep targets earlier step;
//      iterates must be self-loop
//

import Foundation

public struct WorkflowLifecycleDefinitionValidator: Sendable {
    public nonisolated init() {}

    /// Validate lifecycle policy on a compiled definition.
    /// Throws `WorkflowLifecycleError` on the first violation found.
    public nonisolated func validate(_ validated: ValidatedWorkflowDefinition) throws {
        let def = validated.definition
        let steps = def.steps
        let stepIndex = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($0.element.id, $0.offset) })

        for step in steps {
            if step.isTerminal && !step.transitions.isEmpty {
                throw WorkflowLifecycleError.terminalStepHasTransitions(step.id)
            }
            if !step.isTerminal && step.transitions.isEmpty {
                throw WorkflowLifecycleError.nonterminalStepHasNoTransitions(step.id)
            }
            if step.kind == .closure && !step.isTerminal {
                throw WorkflowLifecycleError.closureStepNotTerminal(step.id)
            }

            var seenLabels = Set<String>()
            var seenForwardTargets = Set<StepDefinitionID>()
            for t in step.transitions {
                guard !t.label.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw WorkflowLifecycleError.blankTransitionLabel(stepID: step.id)
                }
                if !seenLabels.insert(t.label).inserted {
                    throw WorkflowLifecycleError.duplicateTransitionLabel(stepID: step.id, label: t.label)
                }
                // Decision steps allow multiple branches to the same target (e.g. yes/no → done).
                // Return transitions may also share a target with a forward transition.
                // Only check duplicate forward targets for non-return non-decision transitions.
                if !t.isReturn && step.kind != .decision {
                    if !seenForwardTargets.insert(t.targetStepID).inserted {
                        throw WorkflowLifecycleError.duplicateTransitionTarget(stepID: step.id, targetStepID: t.targetStepID)
                    }
                }
            }

            if step.kind == .decision {
                let forwardTransitions = step.transitions.filter { !$0.isReturn }
                let branchSet = Set(step.decisionBranches)
                let transitionLabelSet = Set(forwardTransitions.map { $0.label })
                for branch in step.decisionBranches {
                    if !transitionLabelSet.contains(branch) {
                        throw WorkflowLifecycleError.decisionBranchTransitionMismatch(stepID: step.id, branch: branch)
                    }
                }
                for t in forwardTransitions {
                    if !branchSet.contains(t.label) {
                        throw WorkflowLifecycleError.undeclaredDecisionBranch(stepID: step.id, branch: t.label)
                    }
                    if t.condition != nil {
                        throw WorkflowLifecycleError.decisionBranchWithCondition(stepID: step.id)
                    }
                }
            }

            if step.kind == .humanApproval {
                var seenRoles = Set<String>()
                for role in step.approverRoles {
                    guard !role.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw WorkflowLifecycleError.humanApprovalBlankRole(stepID: step.id)
                    }
                    if !seenRoles.insert(role).inserted {
                        throw WorkflowLifecycleError.humanApprovalDuplicateRole(stepID: step.id, role: role)
                    }
                }
                for t in step.transitions where !t.isReturn {
                    if t.condition != nil {
                        throw WorkflowLifecycleError.humanApprovalConditionedTransition(stepID: step.id)
                    }
                }
            }

            for t in step.transitions where t.isReturn {
                guard let policy = step.loopPolicy else {
                    throw WorkflowLifecycleError.returnTransitionMissingLoopPolicy(stepID: step.id)
                }
                switch policy {
                case .returnsToStep:
                    guard let sourceIdx = stepIndex[step.id],
                          let targetIdx = stepIndex[t.targetStepID] else { break }
                    if targetIdx >= sourceIdx {
                        throw WorkflowLifecycleError.returnTransitionToLaterStep(
                            stepID: step.id, targetStepID: t.targetStepID)
                    }
                case .iterates:
                    if t.targetStepID != step.id {
                        throw WorkflowLifecycleError.invalidSelfReturn(stepID: step.id)
                    }
                }
            }
        }
    }
}
