//
//  WorkflowDefinitionCompiler.swift
//  Kalsmritikosh
//
//  PJE-001 — Deterministic workflow-definition compiler/validator.
//
//  Transforms a `PersonaWorkflowDefinition` into a `ValidatedWorkflowDefinition` or
//  throws `WorkflowDefinitionError` with a precise diagnostic. All checks are
//  deterministic: the same input always produces the same output or the same error.
//
//  Checks (in order):
//    1. Duplicate step IDs
//    2. Exactly one entry step
//    3. Unknown transition targets
//    4. Step-kind invariants: decision branches, approver roles, work-product template,
//       closure validation-bypass
//    5. Unreachable steps (BFS from entry)
//    6. No reachable terminal step
//    7. Undeclared cycles (DFS back-edge detection)
//

import Foundation

/// Precise diagnostics from `WorkflowDefinitionCompiler`.
public enum WorkflowDefinitionError: Error, Sendable, Equatable {
    case duplicateStepID(StepDefinitionID)
    case missingEntryStep(WorkflowDefinitionID)
    case multipleEntrySteps([StepDefinitionID])
    case noTerminalPath(WorkflowDefinitionID)
    case unknownTransitionTarget(from: StepDefinitionID, target: StepDefinitionID)
    case unreachableStep(StepDefinitionID)
    case undeclaredCycleInStep(StepDefinitionID)
    case decisionStepMissingBranches(StepDefinitionID)
    case humanApprovalStepMissingApproverRequirement(StepDefinitionID)
    case workProductStepMissingTemplate(StepDefinitionID)
    case closureStepBypassesRequiredValidation(StepDefinitionID, validationID: String)
}

/// The result of a successful compile: the original definition plus derived structural
/// invariants referenced by the runtime (PJE-004/PJE-005).
public nonisolated struct ValidatedWorkflowDefinition: Sendable {
    public let definition: PersonaWorkflowDefinition
    public let entryStepID: StepDefinitionID
    public let terminalStepIDs: Set<StepDefinitionID>
    /// All step IDs reachable from the entry step via the transition graph.
    public let reachableStepIDs: Set<StepDefinitionID>

    public nonisolated init(
        definition: PersonaWorkflowDefinition,
        entryStepID: StepDefinitionID,
        terminalStepIDs: Set<StepDefinitionID>,
        reachableStepIDs: Set<StepDefinitionID>
    ) {
        self.definition        = definition
        self.entryStepID       = entryStepID
        self.terminalStepIDs   = terminalStepIDs
        self.reachableStepIDs  = reachableStepIDs
    }
}

/// Compiles a `PersonaWorkflowDefinition` into a `ValidatedWorkflowDefinition`.
/// Stateless — the same input always yields the same output.
public struct WorkflowDefinitionCompiler: Sendable {
    public nonisolated init() {}

    public func compile(
        _ definition: PersonaWorkflowDefinition
    ) throws -> ValidatedWorkflowDefinition {
        let steps = definition.steps

        // 1. Duplicate step IDs
        var seenIDs = Set<StepDefinitionID>()
        for step in steps {
            guard !seenIDs.contains(step.id) else {
                throw WorkflowDefinitionError.duplicateStepID(step.id)
            }
            seenIDs.insert(step.id)
        }

        // 2. Exactly one entry step
        let entrySteps = steps.filter { $0.isEntry }
        if entrySteps.isEmpty {
            throw WorkflowDefinitionError.missingEntryStep(definition.id)
        }
        if entrySteps.count > 1 {
            throw WorkflowDefinitionError.multipleEntrySteps(entrySteps.map { $0.id })
        }
        let entryStepID = entrySteps[0].id
        let stepMap = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })

        // 3. Unknown transition targets
        for step in steps {
            for t in step.transitions where stepMap[t.targetStepID] == nil {
                throw WorkflowDefinitionError.unknownTransitionTarget(
                    from: step.id, target: t.targetStepID)
            }
        }

        // 4. Step-kind invariants
        for step in steps {
            switch step.kind {
            case .decision:
                if step.decisionBranches.isEmpty {
                    throw WorkflowDefinitionError.decisionStepMissingBranches(step.id)
                }
            case .humanApproval:
                if step.approverRoles.isEmpty {
                    throw WorkflowDefinitionError.humanApprovalStepMissingApproverRequirement(step.id)
                }
            case .workProductBuild:
                guard step.artifacts.contains(where: { $0.workProductTemplateID != nil }) else {
                    throw WorkflowDefinitionError.workProductStepMissingTemplate(step.id)
                }
            case .closure:
                // A blocking validation with no corresponding blocking `validationPassed`
                // requirement cannot be enforced at run time — the gate is silently bypassed.
                if let bypassedValidation = step.validations.first(where: { $0.isBlocking }) {
                    let hasPassedRequirement = step.requirements.contains {
                        $0.kind == .validationPassed && $0.isBlocking
                    }
                    if !hasPassedRequirement {
                        throw WorkflowDefinitionError.closureStepBypassesRequiredValidation(
                            step.id, validationID: bypassedValidation.id)
                    }
                }
            default:
                break
            }
        }

        // 5. Reachability from entry (BFS)
        var reachable = Set<StepDefinitionID>([entryStepID])
        var queue: [StepDefinitionID] = [entryStepID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for t in (stepMap[current]?.transitions ?? []) {
                if reachable.insert(t.targetStepID).inserted {
                    queue.append(t.targetStepID)
                }
            }
        }
        for step in steps where !reachable.contains(step.id) {
            throw WorkflowDefinitionError.unreachableStep(step.id)
        }

        // 6. At least one terminal step reachable from entry
        let terminalStepIDs = Set(steps.filter { $0.isTerminal }.map { $0.id })
        if terminalStepIDs.intersection(reachable).isEmpty {
            throw WorkflowDefinitionError.noTerminalPath(definition.id)
        }

        // 7. Undeclared cycle detection (DFS back-edge check)
        var inPath = Set<StepDefinitionID>()
        var done   = Set<StepDefinitionID>()
        try detectCycles(stepID: entryStepID, stepMap: stepMap, inPath: &inPath, done: &done)

        return ValidatedWorkflowDefinition(
            definition: definition,
            entryStepID: entryStepID,
            terminalStepIDs: terminalStepIDs,
            reachableStepIDs: reachable
        )
    }

    // MARK: - Private

    private func detectCycles(
        stepID: StepDefinitionID,
        stepMap: [StepDefinitionID: PersonaWorkflowStepDefinition],
        inPath: inout Set<StepDefinitionID>,
        done: inout Set<StepDefinitionID>
    ) throws {
        guard !done.contains(stepID) else { return }
        inPath.insert(stepID)
        for t in (stepMap[stepID]?.transitions ?? []) {
            if inPath.contains(t.targetStepID) {
                if !t.isReturn {
                    throw WorkflowDefinitionError.undeclaredCycleInStep(stepID)
                }
            } else if !done.contains(t.targetStepID) {
                try detectCycles(
                    stepID: t.targetStepID, stepMap: stepMap, inPath: &inPath, done: &done)
            }
        }
        inPath.remove(stepID)
        done.insert(stepID)
    }
}
