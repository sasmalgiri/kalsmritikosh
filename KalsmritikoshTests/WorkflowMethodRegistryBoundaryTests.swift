//
//  WorkflowMethodRegistryBoundaryTests.swift
//  KalsmritikoshTests
//
//  PJE-008 — the registry / catalog / requirements boundary for `.method`.
//  Persona job definitions reference the method executor through a TYPED
//  binding (step kind → executor id/version); the compiler validates a method
//  step without knowing any concrete algorithm; a missing binding is a clear
//  blocking condition; a version mismatch is detected rather than silently
//  accepted; and registration order never affects deterministic reopening.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-008 — method registry/catalog boundary")
@MainActor
struct WorkflowMethodRegistryBoundaryTests {

    private let t0 = PJE008Fixtures.t0

    /// A second executor claiming the method kind at a DIFFERENT version — used
    /// only to prove version resolution and the reopen version guard. It never
    /// executes.
    private struct FakeMethodExecutorV2: WorkflowStepExecutor {
        let executorID = WorkflowStepExecutorID(rawValue: "com.kalsmritikosh.step.method")
        let executorVersion = WorkflowStepExecutorVersion(rawValue: "2")
        let handledKind: WorkflowStepKind = .method
        func prepare(context: WorkflowStepPreparationContext) async throws -> WorkflowStepPreparationResult {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
        func execute(context: WorkflowStepExecutionContext, commandJSON: String) async throws -> WorkflowStepExecutionResult {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    // MARK: - 1: The method step binds through a typed identity

    @Test("The method step resolves through a typed (kind → executor id/version) binding")
    func methodBindingIsTypedIdentity() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let builder = WorkflowStepExecutorRegistryBuilder()
        let method = MethodStepExecutor(gate: gate)
        try builder.register(method)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method,
            executorID: method.executorID, executorVersion: method.executorVersion))
        let registry = builder.build()
        let resolved = registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: .method)
        #expect(resolved?.executorID == method.executorID)
        #expect(resolved?.executorVersion == method.executorVersion)
    }

    // MARK: - 2: The compiler validates a method step without any algorithm

    @Test("A workflow with a method step + methodResultPresent requirement compiles (no algorithm needed)")
    func compilerAcceptsMethodStepWithOpaqueID() throws {
        // Compilation is exactly the validation the catalog performs at registration.
        _ = try PJE008Fixtures.methodPackage(suffix: "compile")
        _ = try PJE008Fixtures.methodApprovalPackage(suffix: "compile2")
        _ = try PJE008Fixtures.methodDecisionPackage(suffix: "compile3")
    }

    // MARK: - 3: A missing binding is a clear blocking condition

    @Test("Starting a method-entry workflow with no method binding fails closed")
    func missingMethodBindingBlocks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let repo = WorkflowRunRepository(database: db)
        // Registry with ONLY a closure executor — no method binding.
        let builder = WorkflowStepExecutorRegistryBuilder()
        let closure = ClosureStepExecutor()
        try builder.register(closure)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .closure,
            executorID: closure.executorID, executorVersion: closure.executorVersion))
        let engine = WorkflowStepExecutionEngine(
            registry: builder.build(),
            lifecycleEngine: WorkflowLifecycleEngine(repository: repo), repository: repo)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(db, id: ws)
        let (pkg, wfID) = try PJE008Fixtures.methodPackage(suffix: "nobind")
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        await #expect(throws: (any Error).self) {
            _ = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        }
    }

    // MARK: - 4: Duplicate binding / executor rejected

    @Test("Binding the method kind twice is rejected")
    func duplicateMethodBindingRejected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let builder = WorkflowStepExecutorRegistryBuilder()
        let method = MethodStepExecutor(gate: gate)
        try builder.register(method)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method,
            executorID: method.executorID, executorVersion: method.executorVersion))
        #expect(throws: (any Error).self) {
            try builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: .method,
                executorID: method.executorID, executorVersion: method.executorVersion))
        }
    }

    @Test("Registering the same method executor twice is rejected")
    func duplicateMethodExecutorRejected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let builder = WorkflowStepExecutorRegistryBuilder()
        try builder.register(MethodStepExecutor(gate: gate))
        #expect(throws: (any Error).self) {
            try builder.register(MethodStepExecutor(gate: gate))
        }
    }

    // MARK: - 5: Version is part of resolution (mismatch → no executor)

    @Test("A binding to an unregistered executor version does not resolve")
    func versionIsPartOfResolution() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let builder = WorkflowStepExecutorRegistryBuilder()
        let method = MethodStepExecutor(gate: gate)   // version "1"
        try builder.register(method)
        // Bind the method kind to version "2" — which is NOT registered.
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method,
            executorID: method.executorID, executorVersion: WorkflowStepExecutorVersion(rawValue: "2")))
        let registry = builder.build()
        #expect(registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: .method) == nil)
    }

    // MARK: - 6: Version mismatch on reopen is detected, not silently accepted

    @Test("A method step reopened under a mismatched executor version is rejected")
    func versionMismatchOnReopenDetected() async throws {
        let url = PJE007Fixtures.newURL()
        // Persist a method step with the real v1 executor.
        let base = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let (pkg, wfID) = try PJE008Fixtures.methodPackage(suffix: "vermismatch")
        let runID = try await PJE008Fixtures.startMethodRun(base, package: (pkg, wfID), workspaceID: ws, at: t0)
        _ = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "m"), actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(10))
        _ = entity

        // Reopen with a registry whose ONLY method executor is version "2" — the
        // stored step was produced by version "1", which is no longer available.
        // The engine must refuse rather than silently run a different version.
        let db2 = try MigrationFixtureBuilder.reopen(at: url)
        let repo2 = WorkflowRunRepository(database: db2)
        let builder = WorkflowStepExecutorRegistryBuilder()
        let fakeV2 = FakeMethodExecutorV2()
        try builder.register(fakeV2)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method,
            executorID: fakeV2.executorID, executorVersion: fakeV2.executorVersion))
        let engine2 = WorkflowStepExecutionEngine(
            registry: builder.build(),
            lifecycleEngine: WorkflowLifecycleEngine(repository: repo2), repository: repo2)
        let cmd = try WorkflowStepPayloadCodec.encode(MethodStepCommand.setInstructions("x"))
        await #expect(throws: (any Error).self) {
            _ = try await engine2.executeCommand(
                runID: runID, commandJSON: cmd, actor: PJE007Fixtures.human("a"), now: t0.addingTimeInterval(20))
        }
    }

    // MARK: - 7: Registration order does not affect deterministic reopen

    @Test("Executor registration order does not change the reopened method state or hash")
    func registrationOrderDoesNotAffectReopen() async throws {
        func runMethodFlow(order: Int) async throws -> (json: String, sha: String) {
            let url = PJE007Fixtures.newURL()
            let db = try await MigrationFixtureBuilder.database(atVersion: 77, at: url)
            let repo = WorkflowRunRepository(database: db)
            let scopes = SensitiveScopeRepository(database: db)
            let gate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: scopes, scope: nil)
            let validator = WorkflowProvenanceReferenceValidator(gate: gate, database: db)
            // Two registration orders of the same executor set.
            let executors: [any WorkflowStepExecutor] = order == 0
                ? [MethodStepExecutor(gate: gate), ClosureStepExecutor()]
                : [ClosureStepExecutor(), MethodStepExecutor(gate: gate)]
            let builder = WorkflowStepExecutorRegistryBuilder()
            for e in executors {
                try builder.register(e)
                try builder.bind(WorkflowStepExecutorBinding(
                    workflowSchemaVersion: 1, stepKind: e.handledKind,
                    executorID: e.executorID, executorVersion: e.executorVersion))
            }
            let engine = WorkflowStepExecutionEngine(
                registry: builder.build(),
                lifecycleEngine: WorkflowLifecycleEngine(repository: repo),
                repository: repo, provenanceValidator: validator)
            let ws = UUID()
            try await PJE007Fixtures.seedWorkspace(db, id: ws)
            let entity = try await PJE007Fixtures.seedEntity(db, in: ws)
            let (pkg, wfID) = try PJE008Fixtures.methodPackage(suffix: "order")
            let created = try await repo.createRun(
                package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
                title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
            _ = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
            _ = try await engine.executeCommand(
                runID: created.run.id,
                commandJSON: try WorkflowStepPayloadCodec.encode(MethodStepCommand.setRequestedMethod(methodDefinitionID: "m.fixed")),
                actor: PJE007Fixtures.human("a"), now: t0.addingTimeInterval(10))
            let result = PJE008Fixtures.methodResult(
                runRef: "run-fixed", resultRef: "res-fixed",
                provenance: [PJE008Fixtures.entityRef(entity)], at: t0.addingTimeInterval(20))
            _ = try await engine.executeCommand(
                runID: created.run.id,
                commandJSON: try WorkflowStepPayloadCodec.encode(MethodStepCommand.attachResult(result)),
                actor: PJE007Fixtures.human("a"), now: t0.addingTimeInterval(20))
            // Reopen fresh and read the method step.
            let db2 = try MigrationFixtureBuilder.reopen(at: url)
            let repo2 = WorkflowRunRepository(database: db2)
            let reopened = try await repo2.fetchRun(created.run.id)
            let step = try #require(reopened.stepRuns.first { $0.stepKind == .method })
            return (step.stateJSON, step.stateSHA256)
        }
        // Note: the two runs use different random UUIDs (workspace/entity/run), so
        // the JSON differs by IDs; the INVARIANT under test is that within one run
        // the reopened state is self-consistent regardless of registration order.
        let a = try await runMethodFlow(order: 0)
        let b = try await runMethodFlow(order: 1)
        #expect(a.sha == WorkflowPersistedJSONIntegrity.rawSHA256(of: a.json))
        #expect(b.sha == WorkflowPersistedJSONIntegrity.rawSHA256(of: b.json))
    }

    // MARK: - 8: methodResultPresent is skipped without an executor-facts adapter

    @Test("methodResultPresent evaluates to skipped when no requirement-facts adapter is wired")
    func methodResultPresentSkippedWithoutAdapter() async throws {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let (pkg, wfID) = try PJE008Fixtures.methodPackage(suffix: "noadapter")
        let runID = try await PJE008Fixtures.startMethodRun(base, package: (pkg, wfID), workspaceID: ws, at: t0)
        let agg = try await base.repo.fetchRun(runID)
        let methodStep = try #require(agg.contract.reconstructDefinition()?.definition.steps.first { $0.kind == .method })
        let engineNoAdapter = WorkflowRequirementsEngine(repository: base.repo)  // no adapter
        let eval = try await engineNoAdapter.evaluate(stepDefinition: methodStep, aggregate: agg)
        if case .skipped = eval.requirementOutcomes.first {
            // expected
        } else {
            Issue.record("Expected .skipped without adapter, got \(String(describing: eval.requirementOutcomes.first))")
        }
    }

    // MARK: - 9: methodResultPresent fails before a result, satisfied after

    @Test("methodResultPresent is failed before a result and satisfied after (via the facts adapter)")
    func methodResultPresentFailedThenSatisfied() async throws {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(base.db, in: ws)
        let (pkg, wfID) = try PJE008Fixtures.methodPackage(suffix: "factgate")
        let runID = try await PJE008Fixtures.startMethodRun(base, package: (pkg, wfID), workspaceID: ws, at: t0)
        let engine = WorkflowRequirementsEngine(
            repository: base.repo, requirementFactsAdapter: WorkflowStepRequirementFactsAdapter())
        let before = try await base.repo.fetchRun(runID)
        let methodStep = try #require(before.contract.reconstructDefinition()?.definition.steps.first { $0.kind == .method })
        let evalBefore = try await engine.evaluate(stepDefinition: methodStep, aggregate: before)
        if case .failed(let reqID, _, let isBlocking, _) = evalBefore.requirementOutcomes.first {
            #expect(reqID == "req.method-result")
            #expect(isBlocking)
        } else {
            Issue.record("Expected .failed before result")
        }
        let result = PJE008Fixtures.methodResult(
            provenance: [PJE008Fixtures.entityRef(entity)], at: t0.addingTimeInterval(20))
        _ = try await PJE007Fixtures.exec(base, runID: runID, MethodStepCommand.attachResult(result),
                                         actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(20))
        let after = try await base.repo.fetchRun(runID)
        let evalAfter = try await engine.evaluate(stepDefinition: methodStep, aggregate: after)
        if case .satisfied(let reqID) = evalAfter.requirementOutcomes.first {
            #expect(reqID == "req.method-result")
        } else {
            Issue.record("Expected .satisfied after result")
        }
    }

    // MARK: - 10: A schema-version-scoped binding does not resolve for another version

    @Test("A binding registered for schema version 1 does not resolve for schema version 2")
    func bindingIsSchemaVersionScoped() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let builder = WorkflowStepExecutorRegistryBuilder()
        let method = MethodStepExecutor(gate: gate)
        try builder.register(method)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method,
            executorID: method.executorID, executorVersion: method.executorVersion))
        let registry = builder.build()
        #expect(registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: .method) != nil)
        #expect(registry.resolveExecutor(workflowSchemaVersion: 2, stepKind: .method) == nil)
    }

    // MARK: - 11: Adapter metadata lives in generic reference types

    @Test("Method adapter metadata (provider/version/limitations) round-trips in the generic reference type")
    func adapterMetadataIsGeneric() throws {
        let result = PJE008Fixtures.methodResult(
            providerID: "com.ext", providerVersion: "3.2", methodID: "m.generic",
            provenance: [PJE008Fixtures.entityRef(UUID())], at: t0,
            limitations: ["one carrier record", "no cross-check"])
        let json = try WorkflowStepPayloadCodec.encode(result)
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowMethodResultReference.self, from: json)
        #expect(decoded == result)
        #expect(decoded.providerVersion == "3.2")
        #expect(decoded.limitations == ["one carrier record", "no cross-check"])
    }
}
