//
//  WorkflowMethodBoundaryGuardTests.swift
//  KalsmritikoshTests
//
//  PJE-008 — architecture guards proving the Stage 3 `.method` step remains a
//  GENERIC adapter and that NO Stage 4 Professional Method Engine (Five Whys,
//  Fishbone, Hypothesis Matrix, Root-Cause Assessment, CAPA, Timeline Analysis
//  engine, Contradiction Matrix engine, Risk Matrix, Decision Matrix, or any
//  future concrete method) is declared, imported, switched over, persisted in
//  method-specific columns, or executed inside Stage 3.
//
//  Boundary DOCUMENTATION may NAME these concepts; only their DECLARATION,
//  execution, or persistence inside Stage 3 is forbidden.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-008 — method boundary architecture guards")
struct WorkflowMethodBoundaryGuardTests {

    // MARK: - Source access (repo-relative from this file's compile-time path)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KalsmritikoshTests
            .deletingLastPathComponent()   // repo root
    }

    private static func swiftFiles(under relativeDir: String) throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent(relativeDir)
        var out: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Concrete Stage 4 professional-method concepts that must never be DECLARED
    /// as a type inside Stage 3.
    private static let stage4Concepts = [
        "FiveWhys", "Fishbone", "HypothesisMatrix", "RootCauseAssessment", "RootCause",
        "CAPA", "TimelineAnalysisEngine", "ContradictionMatrixEngine", "ContradictionMatrix",
        "RiskMatrix", "DecisionMatrix",
        "ProfessionalMethodDefinition", "MethodRun", "MethodNode", "MethodEdge"
    ]

    private func declaresType(_ text: String, _ concept: String) -> Bool {
        text.range(
            of: "(struct|class|enum|actor|protocol)\\s+\(concept)\\b",
            options: .regularExpression) != nil
    }

    // MARK: - 1: No Stage 4 method type is declared anywhere in Workflow/

    @Test("No Stage 4 professional-method type is declared anywhere in Stage 3 (Workflow/)")
    func noStage4TypeDeclaredInWorkflow() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Workflow") {
            for concept in Self.stage4Concepts {
                #expect(!declaresType(text, concept),
                        "\(name) must not declare Stage 4 method type '\(concept)'")
            }
        }
    }

    // MARK: - 2: No Stage 4 method type is declared in Storage/ or Core/Models

    @Test("No Stage 4 professional-method type is declared in Storage/ or Core/Models")
    func noStage4TypeDeclaredInStorageOrModels() throws {
        for dir in ["Kalsmritikosh/Storage", "Kalsmritikosh/Core/Models"] {
            for (name, text) in try Self.swiftFiles(under: dir) {
                for concept in Self.stage4Concepts {
                    #expect(!declaresType(text, concept),
                            "\(name) must not declare Stage 4 method type '\(concept)'")
                }
            }
        }
    }

    // MARK: - 3: The method executor has no switch over named professional methods

    @Test("MethodStepExecutor names no concrete professional method (no named-method switch)")
    func methodExecutorHasNoNamedMethodSwitch() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        let bannedNames = ["fiveWhys", "fishbone", "hypothesisMatrix", "rootCause",
                           "capa", "riskMatrix", "decisionMatrix", "contradictionMatrix"]
        let lower = text.lowercased()
        for banned in bannedNames {
            #expect(!lower.contains(banned.lowercased()),
                    "MethodStepExecutor must not reference the concrete method '\(banned)'")
        }
    }

    // MARK: - 4: The method layer performs no LLM or network access

    @Test("The method executor and bridge perform no LLM or network access")
    func methodLayerNoLLMorNetwork() throws {
        let files = [
            "Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift",
            "Kalsmritikosh/Workflow/Execution/Bridges/WorkflowMethodResultBridge.swift"
        ]
        let banned = ["URLSession", "URLRequest", "URL(string:", "http://", "https://",
                      "Ollama", "ollama", "LLMClient", "prompt("]
        for file in files {
            let text = try Self.source(file)
            for token in banned {
                #expect(!text.contains(token),
                        "\(file) must not reference network/LLM token '\(token)'")
            }
        }
    }

    // MARK: - 5: The method executor is repository-free and holds no canonical stores

    @Test("MethodStepExecutor references no Database, Repository, or canonical store")
    func methodExecutorRepositoryFree() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        let banned = ["Database", "Repository", "EvidenceStore", "ClaimProducer",
                      "WorkProductAssemblyService"]
        for token in banned {
            #expect(!text.contains(token),
                    "MethodStepExecutor must not reference '\(token)' — it depends only on the gate")
        }
    }

    // MARK: - 6: The method executor never converts a result into a Claim

    @Test("MethodStepExecutor never constructs or persists a Claim")
    func methodExecutorNoClaimConversion() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        let banned = ["Claim(", "ClaimRepository", "insertClaim", "confirmFact",
                      "GenericFact(", "Assertion("]
        for token in banned {
            #expect(!text.contains(token),
                    "MethodStepExecutor must not create canonical facts ('\(token)')")
        }
    }

    // MARK: - 7: The method step makes no human decision

    @Test("MethodStepExecutor records no human decision or approval")
    func methodExecutorMakesNoHumanDecision() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        let banned = ["recordHumanDecision", "insertDecision", "WorkflowDecision(",
                      "humanDecision", "submitHumanApproval", "recordHumanApproval"]
        for token in banned {
            #expect(!text.contains(token),
                    "MethodStepExecutor must not make a human decision ('\(token)')")
        }
    }

    // MARK: - 8: The method executor still gates evidence references (not bypassed)

    @Test("MethodStepExecutor still validates canonical provenance through the gate")
    func methodExecutorGatesEvidence() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        #expect(text.contains("gate.verdict"),
                "MethodStepExecutor must gate canonical provenance references (evidence validation not bypassed)")
        #expect(text.contains("executorKindMismatch"),
                "MethodStepExecutor must guard its handled step kind")
    }

    // MARK: - 9: The result bridge is a reference envelope, not an engine

    @Test("WorkflowMethodResultBridge declares no Stage 4 type and executes no method")
    func bridgeIsReferenceEnvelopeOnly() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Bridges/WorkflowMethodResultBridge.swift")
        for concept in Self.stage4Concepts {
            #expect(!declaresType(text, concept),
                    "WorkflowMethodResultBridge must not declare Stage 4 type '\(concept)'")
        }
        // Reference envelopes validate structure but never compute/analyze/run a method.
        #expect(text.contains("validateStructure"))
        for token in ["func compute", "func analyze(", "func run(", "func execute("] {
            #expect(!text.contains(token),
                    "WorkflowMethodResultBridge must not execute a method ('\(token)')")
        }
    }

    // MARK: - 10: No method-run tables exist in any migration

    @Test("No Stage 4 method table is created in any schema migration")
    func noMethodTablesInSchema() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        let bannedTables = [
            "CREATE TABLE method_runs", "CREATE TABLE professional_method",
            "CREATE TABLE method_nodes", "CREATE TABLE method_edges",
            "CREATE TABLE five_whys", "CREATE TABLE fishbone",
            "CREATE TABLE root_cause", "CREATE TABLE capa"
        ]
        for token in bannedTables {
            #expect(!schema.contains(token), "Schema must not create Stage 4 table via '\(token)'")
        }
    }

    // MARK: - 11: Workflow core tables carry no method-specific columns

    @Test("Workflow core tables carry no method-specific columns")
    func workflowCoreTablesHaveNoMethodColumns() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        // Method state/results live inside the GENERIC step-state JSON, never as
        // dedicated columns on the workflow core tables.
        let bannedColumns = [
            "method_definition_id", "method_run_id", "method_result_id",
            "root_cause", "five_whys", "fishbone_", "hypothesis_matrix",
            "risk_matrix", "decision_matrix"
        ]
        for token in bannedColumns {
            #expect(!schema.contains(token),
                    "Workflow schema must not persist method-specific column '\(token)'")
        }
    }

    // MARK: - 12: The method executor version is a stable, typed identity

    @Test("The method executor exposes a stable typed id/version and handles the method kind")
    func methodExecutorTypedIdentity() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        #expect(text.contains("com.kalsmritikosh.step.method"))
        #expect(text.contains("handledKind: WorkflowStepKind = .method"))
    }
}
