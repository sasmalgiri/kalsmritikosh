//
//  WorkflowStepExecutorRegistryTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — Registry builder, dual lookup, duplicate guards.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepExecutorRegistry")
struct WorkflowStepExecutorRegistryTests {

    // MARK: - Empty registry

    @Test("empty registry returns nil for exact lookup")
    func emptyExactLookup() {
        let r = WorkflowStepExecutorRegistryBuilder().build()
        let id = WorkflowStepExecutorID(rawValue: "com.test")
        let ver = WorkflowStepExecutorVersion(rawValue: "1.0")
        #expect(r.executor(id: id, version: ver) == nil)
    }

    @Test("empty registry returns nil for binding lookup")
    func emptyBindingLookup() {
        let r = WorkflowStepExecutorRegistryBuilder().build()
        #expect(r.binding(workflowSchemaVersion: 1, stepKind: .intake) == nil)
    }

    @Test("empty registry resolveExecutor returns nil")
    func emptyResolveExecutor() {
        let r = WorkflowStepExecutorRegistryBuilder().build()
        #expect(r.resolveExecutor(workflowSchemaVersion: 1, stepKind: .intake) == nil)
    }

    // MARK: - Register

    @Test("register and exact lookup returns the executor")
    func registerAndLookup() throws {
        let exec = IntakeStepExecutor()
        let r = try WorkflowStepExecutorRegistryBuilder().register(exec).build()
        let found = r.executor(id: exec.executorID, version: exec.executorVersion)
        #expect(found != nil)
        #expect(found?.executorID == exec.executorID)
    }

    @Test("register duplicate throws duplicateExecutor")
    func registerDuplicate() {
        let builder = WorkflowStepExecutorRegistryBuilder()
        let exec = IntakeStepExecutor()
        #expect(throws: WorkflowStepExecutionError.duplicateExecutor(
            id: exec.executorID, version: exec.executorVersion)) {
            try builder.register(exec)
            try builder.register(exec)
        }
    }

    // MARK: - Bind

    @Test("bind and lookup returns the binding")
    func bindAndLookup() throws {
        let exec = ScopeStepExecutor()
        let binding = WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .scope,
            executorID: exec.executorID, executorVersion: exec.executorVersion
        )
        let r = try WorkflowStepExecutorRegistryBuilder()
            .register(exec)
            .bind(binding)
            .build()
        let found = r.binding(workflowSchemaVersion: 1, stepKind: .scope)
        #expect(found?.executorID == exec.executorID)
    }

    @Test("bind duplicate throws duplicateBinding")
    func bindDuplicate() throws {
        let exec = ScopeStepExecutor()
        let binding = WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .scope,
            executorID: exec.executorID, executorVersion: exec.executorVersion
        )
        let builder = WorkflowStepExecutorRegistryBuilder()
        try builder.register(exec)
        #expect(throws: WorkflowStepExecutionError.duplicateBinding(
            workflowSchemaVersion: 1, kind: .scope)) {
            try builder.bind(binding)
            try builder.bind(binding)
        }
    }

    // MARK: - resolveExecutor

    @Test("resolveExecutor returns executor when both binding and executor registered")
    func resolveExecutorFullPath() throws {
        let exec = IntakeStepExecutor()
        let binding = WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .intake,
            executorID: exec.executorID, executorVersion: exec.executorVersion
        )
        let r = try WorkflowStepExecutorRegistryBuilder()
            .register(exec)
            .bind(binding)
            .build()
        let resolved = r.resolveExecutor(workflowSchemaVersion: 1, stepKind: .intake)
        #expect(resolved?.handledKind == .intake)
    }

    @Test("resolveExecutor returns nil when binding missing")
    func resolveExecutorMissingBinding() throws {
        let exec = IntakeStepExecutor()
        let r = try WorkflowStepExecutorRegistryBuilder().register(exec).build()
        #expect(r.resolveExecutor(workflowSchemaVersion: 1, stepKind: .intake) == nil)
    }

    @Test("resolveExecutor returns nil when executor missing despite binding")
    func resolveExecutorMissingExecutor() throws {
        let exec = IntakeStepExecutor()
        let binding = WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .intake,
            executorID: exec.executorID, executorVersion: exec.executorVersion
        )
        // Register binding but not the executor itself
        let r = try WorkflowStepExecutorRegistryBuilder().bind(binding).build()
        #expect(r.resolveExecutor(workflowSchemaVersion: 1, stepKind: .intake) == nil)
    }

    @Test("multiple executors coexist in registry")
    func multipleExecutors() throws {
        let intake = IntakeStepExecutor()
        let scope = ScopeStepExecutor()
        let r = try WorkflowStepExecutorRegistryBuilder()
            .register(intake)
            .register(scope)
            .build()
        #expect(r.executor(id: intake.executorID, version: intake.executorVersion)?.handledKind == .intake)
        #expect(r.executor(id: scope.executorID, version: scope.executorVersion)?.handledKind == .scope)
    }
}
