//
//  WorkflowStepExecutorRegistry.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Immutable executor registry with dual lookup:
//    1. Exact (executorID, executorVersion) → executor instance
//    2. Deterministic binding (workflowSchemaVersion, stepKind) → (id, version)
//
//  Built once, read-only after construction. Thread-safe by value semantics.
//

import Foundation

// MARK: - Registry

/// Immutable, thread-safe registry of step executor instances and their bindings.
/// Construct once via the builder; share freely across actors.
public nonisolated struct WorkflowStepExecutorRegistry: Sendable {

    // Keyed by (id.rawValue, version.rawValue)
    private let executors: [String: any WorkflowStepExecutor]

    // Keyed by (workflowSchemaVersion, stepKind.rawValue)
    private let bindings: [String: WorkflowStepExecutorBinding]

    fileprivate nonisolated init(
        executors: [String: any WorkflowStepExecutor],
        bindings: [String: WorkflowStepExecutorBinding]
    ) {
        self.executors = executors
        self.bindings = bindings
    }

    // MARK: - Exact lookup

    /// Returns the executor registered under the exact (id, version) pair.
    /// Returns `nil` if no executor was registered with those exact values.
    public nonisolated func executor(
        id: WorkflowStepExecutorID,
        version: WorkflowStepExecutorVersion
    ) -> (any WorkflowStepExecutor)? {
        executors[executorKey(id: id, version: version)]
    }

    // MARK: - Binding lookup

    /// Returns the deterministic binding for a (workflowSchemaVersion, stepKind) pair.
    /// Returns `nil` if no binding was registered for that combination.
    public nonisolated func binding(
        workflowSchemaVersion: Int,
        stepKind: WorkflowStepKind
    ) -> WorkflowStepExecutorBinding? {
        bindings[bindingKey(schemaVersion: workflowSchemaVersion, kind: stepKind)]
    }

    /// Resolves a binding and then looks up the exact executor instance.
    /// Returns `nil` if either the binding or the executor is missing.
    public nonisolated func resolveExecutor(
        workflowSchemaVersion: Int,
        stepKind: WorkflowStepKind
    ) -> (any WorkflowStepExecutor)? {
        guard let b = binding(
            workflowSchemaVersion: workflowSchemaVersion,
            stepKind: stepKind
        ) else { return nil }
        return executor(id: b.executorID, version: b.executorVersion)
    }

    // MARK: - Private helpers

    private nonisolated func executorKey(
        id: WorkflowStepExecutorID,
        version: WorkflowStepExecutorVersion
    ) -> String {
        "\(id.rawValue)::\(version.rawValue)"
    }

    private nonisolated func bindingKey(
        schemaVersion: Int,
        kind: WorkflowStepKind
    ) -> String {
        "\(schemaVersion)::\(kind.rawValue)"
    }
}

// MARK: - Builder

/// Mutable builder for `WorkflowStepExecutorRegistry`.
public final class WorkflowStepExecutorRegistryBuilder: @unchecked Sendable {

    private var executors: [String: any WorkflowStepExecutor] = [:]
    private var bindings: [String: WorkflowStepExecutorBinding] = [:]

    public init() {}

    // MARK: - Register executor

    /// Registers an executor instance under its declared (executorID, executorVersion).
    /// Throws `WorkflowStepExecutionError.duplicateExecutor` if already registered.
    @discardableResult
    public func register(_ executor: any WorkflowStepExecutor) throws -> Self {
        let key = "\(executor.executorID.rawValue)::\(executor.executorVersion.rawValue)"
        guard executors[key] == nil else {
            throw WorkflowStepExecutionError.duplicateExecutor(
                id: executor.executorID,
                version: executor.executorVersion
            )
        }
        executors[key] = executor
        return self
    }

    // MARK: - Register binding

    /// Registers a deterministic binding from (workflowSchemaVersion, stepKind) to
    /// a specific (executorID, executorVersion).
    /// Throws `WorkflowStepExecutionError.duplicateBinding` if already registered.
    @discardableResult
    public func bind(_ binding: WorkflowStepExecutorBinding) throws -> Self {
        let key = "\(binding.workflowSchemaVersion)::\(binding.stepKind.rawValue)"
        guard bindings[key] == nil else {
            throw WorkflowStepExecutionError.duplicateBinding(
                workflowSchemaVersion: binding.workflowSchemaVersion,
                kind: binding.stepKind
            )
        }
        bindings[key] = binding
        return self
    }

    // MARK: - Build

    /// Produces the immutable registry. The builder is still usable after this call.
    public func build() -> WorkflowStepExecutorRegistry {
        WorkflowStepExecutorRegistry(executors: executors, bindings: bindings)
    }
}
