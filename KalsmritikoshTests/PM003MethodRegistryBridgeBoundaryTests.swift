//
//  PM003MethodRegistryBridgeBoundaryTests.swift
//  KalsmritikoshTests
//
//  PM-003 — architecture guards: no schema change, one code-backed definition
//  authority, no concrete method, the v2 executor depends only on the resolver
//  protocol, the Stage-3 bridge holds reference envelopes only, and the schema-1
//  binding stays v1 while schema-2 resolves v2.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private struct StubGate: WorkflowEvidenceReferenceGating {
    func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict { .permitted }
}

private struct StubResolver: WorkflowProfessionalMethodRunResolving {
    func validateSelection(_ selection: WorkflowProfessionalMethodSelection) async throws {}
    func validateLinkedRun(runID: UUID, selection: WorkflowProfessionalMethodSelection, workspaceID: UUID,
                           workflowRunID: UUID, workflowStepRunID: UUID) async throws -> WorkflowProfessionalMethodRunReference {
        WorkflowProfessionalMethodRunReference(methodRunID: runID, methodDefinitionID: selection.methodDefinitionID, methodDefinitionVersion: selection.methodDefinitionVersion)
    }
    func completedResult(runID: UUID, selection: WorkflowProfessionalMethodSelection, workspaceID: UUID,
                         workflowRunID: UUID, workflowStepRunID: UUID, summary: String, completedBy: String,
                         limitations: [String]) async throws -> WorkflowProfessionalMethodResultReference {
        throw ProfessionalMethodWorkflowBridgeError.methodRunNotFound(runID)
    }
}

@Suite("PM-003 — method registry + bridge boundary guards")
struct PM003MethodRegistryBridgeBoundaryTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }
    private static func swiftFiles(under relativeDir: String) throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent(relativeDir)
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }
    private func declaresType(_ text: String, _ concept: String) -> Bool {
        text.range(of: "(struct|class|enum|actor|protocol)\\s+\(concept)\\b", options: .regularExpression) != nil
    }
    /// Code with `//` comment lines removed — so a guard that bans a dependency
    /// token does not trip on a doc comment that legitimately NAMES the excluded
    /// dependency ("depends only on … never a Database …").
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - No schema change / one definition authority

    @Test("The professional-method registry adds no schema table of its own; the latest schema is v81")
    func registryAddsNoSchemaOfItsOwn() {
        // PM-003 introduced no schema change; the run-state ledger is v79 (PM-002), the
        // generic lifecycle is v80 (PM-004) and its ledger hardening is v81 (PM-004.1).
        // The registry itself remains code-backed with no definition table (see
        // noMethodDefinitionTable below).
        #expect(SchemaMigrations.latestVersion == 81)
    }

    @Test("No method-definition table exists — definitions stay code-registry-backed")
    func noMethodDefinitionTable() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for token in ["CREATE TABLE professional_method_definitions", "CREATE TABLE method_definition_registry",
                      "CREATE TABLE method_templates"] {
            #expect(!schema.contains(token), "no method-definition table may exist ('\(token)')")
        }
    }

    @Test("The professional-method registry is not a ninth PersonaJobCatalog registry")
    func registryStaysSeparateFromCatalog() throws {
        let catalog = try Self.source("Kalsmritikosh/Workflow/Registry/PersonaJobCatalog.swift")
        #expect(!catalog.contains("ProfessionalMethod"),
                "PersonaJobCatalog must not own professional-method definitions")
    }

    // MARK: - No concrete method

    @Test("No concrete Stage 4 method engine is declared in the Method subsystem or executors")
    func noConcreteMethodEngine() throws {
        var files = try Self.swiftFiles(under: "Kalsmritikosh/Method")
        files.append(("RegisteredMethodStepExecutor.swift",
                      try Self.source("Kalsmritikosh/Workflow/Execution/Executors/RegisteredMethodStepExecutor.swift")))
        for (name, text) in files {
            for concept in ["FiveWhys", "Fishbone", "HypothesisMatrix", "RootCauseAssessment",
                            "CAPA", "RiskMatrix", "DecisionMatrix", "ContradictionMatrix"] {
                #expect(!declaresType(text, concept), "\(name) must not declare concrete method '\(concept)'")
            }
        }
    }

    // MARK: - v2 executor depends only on the resolver protocol

    @Test("The v2 executor contains no Database, SQL, MethodRunRepository or registry dependency")
    func v2ExecutorDependsOnlyOnResolver() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/RegisteredMethodStepExecutor.swift")
        let code = codeOnly(text)
        for token in ["Database", "MethodRunRepository", "ProfessionalMethodRegistry",
                      "INSERT INTO", "SELECT ", "db.exec", "db.query", "sqlite3_"] {
            #expect(!code.contains(token), "RegisteredMethodStepExecutor must not reference '\(token)'")
        }
        #expect(text.contains("WorkflowProfessionalMethodRunResolving"))
    }

    // MARK: - Stage-3 bridge holds reference envelopes only

    @Test("The Stage-3 bridge file holds reference envelopes only, and executes no method")
    func bridgeFileIsReferenceEnvelopesOnly() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Bridges/WorkflowMethodResultBridge.swift")
        for concept in ["ProfessionalMethodDefinition", "MethodRun", "MethodNode", "MethodEdge",
                        "MethodFinding", "MethodRunRepository"] {
            #expect(!declaresType(text, concept), "bridge file must not declare Stage-4 type '\(concept)'")
        }
        for token in ["func compute", "func analyze(", "func run(", "func execute("] {
            #expect(!text.contains(token), "bridge file must not execute a method ('\(token)')")
        }
    }

    // MARK: - No Claim mutation / no LLM-UI-network

    @Test("The method registry + bridge + v2 executor mutate no Claim and add no LLM/UI/network")
    func noClaimMutationNoLLMUINetwork() throws {
        var files = try Self.swiftFiles(under: "Kalsmritikosh/Method/Registry")
        files += try Self.swiftFiles(under: "Kalsmritikosh/Method/Bridge")
        files.append(("RegisteredMethodStepExecutor.swift",
                      try Self.source("Kalsmritikosh/Workflow/Execution/Executors/RegisteredMethodStepExecutor.swift")))
        for (name, text) in files {
            for token in ["INSERT INTO claims", "UPDATE claims", "DELETE FROM claims", "Claim(", "ClaimRepository",
                          "import SwiftUI", "import AppKit", "URLSession", "http://", "https://",
                          "Ollama", "LLMClient", "prompt(", "AppState"] {
                #expect(!text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }

    // MARK: - Binding safeguards

    private func bindingRegistry() throws -> WorkflowStepExecutorRegistry {
        let builder = WorkflowStepExecutorRegistryBuilder()
        let v1 = MethodStepExecutor(gate: StubGate())
        try builder.register(v1)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .method, executorID: v1.executorID, executorVersion: v1.executorVersion))
        let v2 = RegisteredMethodStepExecutor(resolver: StubResolver())
        try builder.register(v2)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 2, stepKind: .method, executorID: v2.executorID, executorVersion: v2.executorVersion))
        return builder.build()
    }

    @Test("Schema 1 binds the v1 method executor; schema 2 resolves v2; neither crosses over")
    func schemaBindingsAreExact() throws {
        let registry = try bindingRegistry()
        let one = registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: .method)
        let two = registry.resolveExecutor(workflowSchemaVersion: 2, stepKind: .method)
        #expect(one?.executorVersion.rawValue == "1")
        #expect(two?.executorVersion.rawValue == "2")
        #expect(one?.executorID.rawValue == "com.kalsmritikosh.step.method")
        #expect(two?.executorID.rawValue == "com.kalsmritikosh.step.method")
        // Both exact versions resolve directly.
        #expect(registry.executor(id: WorkflowStepExecutorID(rawValue: "com.kalsmritikosh.step.method"),
                                  version: WorkflowStepExecutorVersion(rawValue: "1")) != nil)
        #expect(registry.executor(id: WorkflowStepExecutorID(rawValue: "com.kalsmritikosh.step.method"),
                                  version: WorkflowStepExecutorVersion(rawValue: "2")) != nil)
    }

    @Test("Duplicate executor registration fails, and an unregistered version does not resolve")
    func duplicateRegistrationAndMissingVersion() throws {
        let builder = WorkflowStepExecutorRegistryBuilder()
        let v2 = RegisteredMethodStepExecutor(resolver: StubResolver())
        try builder.register(v2)
        #expect(throws: (any Error).self) { try builder.register(v2) }   // duplicate exact (id, version)
        let registry = builder.build()
        // Only v2 registered → v1 does not resolve, and no schema-1 binding exists.
        #expect(registry.executor(id: v2.executorID, version: WorkflowStepExecutorVersion(rawValue: "1")) == nil)
        #expect(registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: .method) == nil)
    }
}
