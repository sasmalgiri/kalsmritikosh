//
//  WorkflowRequirementTypes.swift
//  Kalsmritikosh
//
//  PJE-005 — Requirements, Validators, and Attention Engine.
//  Outcome types, full evaluation result, validator execution protocol, and context.
//

import Foundation

// MARK: - Requirement outcome

/// The result of evaluating one PersonaWorkflowRequirement against the current run state.
public enum WorkflowRequirementOutcome: Sendable {
    case satisfied(requirementID: String)
    case failed(requirementID: String, label: String, isBlocking: Bool, detail: String?)
    /// Evaluation not possible (missing context, executor concern, or deferred to PJE-007).
    case skipped(requirementID: String, reason: String?)

    public nonisolated var requirementID: String {
        switch self {
        case .satisfied(let id): return id
        case .failed(let id, _, _, _): return id
        case .skipped(let id, _): return id
        }
    }

    public nonisolated var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public nonisolated var isBlockingFailed: Bool {
        if case .failed(_, _, let blocking, _) = self { return blocking }
        return false
    }
}

// MARK: - Validation outcome

/// The result of executing one PersonaWorkflowValidation against the current step run.
public enum WorkflowValidationOutcome: Sendable {
    case passed(validationID: String)
    case failed(validationID: String, label: String, isBlocking: Bool, detail: String?)
    /// Executor not registered, step kind not supported, or no active step run.
    case skipped(validationID: String, reason: String?)

    public nonisolated var validationID: String {
        switch self {
        case .passed(let id): return id
        case .failed(let id, _, _, _): return id
        case .skipped(let id, _): return id
        }
    }

    public nonisolated var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public nonisolated var isBlockingFailed: Bool {
        if case .failed(_, _, let blocking, _) = self { return blocking }
        return false
    }
}

// MARK: - Full evaluation result

/// The combined result of evaluating all requirements and running all validators for one step.
public struct WorkflowRequirementsEvaluation: Sendable {
    public let requirementOutcomes: [WorkflowRequirementOutcome]
    public let validationOutcomes: [WorkflowValidationOutcome]

    /// True when at least one requirement or validation with isBlocking = true has failed.
    public nonisolated var hasBlockingFailure: Bool {
        requirementOutcomes.contains { $0.isBlockingFailed } ||
        validationOutcomes.contains { $0.isBlockingFailed }
    }

    /// True when any requirement or validation failed (blocking or advisory).
    public nonisolated var hasAnyFailure: Bool {
        requirementOutcomes.contains { $0.isFailed } ||
        validationOutcomes.contains { $0.isFailed }
    }

    public nonisolated init(
        requirementOutcomes: [WorkflowRequirementOutcome],
        validationOutcomes: [WorkflowValidationOutcome]
    ) {
        self.requirementOutcomes = requirementOutcomes
        self.validationOutcomes = validationOutcomes
    }
}

// MARK: - Validator execution context

/// Data passed to a WorkflowValidatorExecuting implementation at run time.
public struct WorkflowValidationContext: Sendable {
    public let stepRun: WorkflowStepRun
    public let stepDefinition: PersonaWorkflowStepDefinition
    public let run: WorkflowRun

    public nonisolated init(
        stepRun: WorkflowStepRun,
        stepDefinition: PersonaWorkflowStepDefinition,
        run: WorkflowRun
    ) {
        self.stepRun = stepRun
        self.stepDefinition = stepDefinition
        self.run = run
    }
}

// MARK: - Validator result

/// The value a WorkflowValidatorExecuting implementation returns.
public struct WorkflowValidationResult: Sendable {
    public let passed: Bool
    public let detail: String?

    public nonisolated init(passed: Bool, detail: String? = nil) {
        self.passed = passed
        self.detail = detail
    }

    public static nonisolated let pass = WorkflowValidationResult(passed: true)

    public static nonisolated func pass(detail: String) -> WorkflowValidationResult {
        WorkflowValidationResult(passed: true, detail: detail)
    }

    public static nonisolated func fail(detail: String? = nil) -> WorkflowValidationResult {
        WorkflowValidationResult(passed: false, detail: detail)
    }
}

// MARK: - Validator execution protocol

/// Implement this protocol and register the executor with WorkflowRequirementsEngine
/// to drive PersonaWorkflowValidation execution.
/// Execution context and result evaluation belong to PJE-005.
public protocol WorkflowValidatorExecuting: Sendable {
    /// Stable ID matching PersonaValidatorDefinition.id.rawValue.
    nonisolated var validatorID: String { get }
    func execute(context: WorkflowValidationContext) async throws -> WorkflowValidationResult
}
