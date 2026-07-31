//
//  PM004MethodLifecycleBoundaryTests.swift
//  KalsmritikoshTests
//
//  PM-004 — architecture guards: schema is exactly v80, no method-definition table,
//  no concrete method, the lifecycle engine mutates no canonical ledger, validators
//  hold no database/repository, reviews stay human-only, no Claim/LLM/UI/network,
//  and the Stage-3 method executor bindings + PM-003 bridge are untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — method lifecycle boundary guards")
struct PM004MethodLifecycleBoundaryTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func source(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }
    private static func swiftFiles(under rel: String) throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent(rel)
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
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("The schema is exactly v80")
    func schemaIsV80() { #expect(SchemaMigrations.latestVersion == 80) }

    @Test("No method-definition table exists")
    func noMethodDefinitionTable() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for t in ["CREATE TABLE professional_method_definitions", "CREATE TABLE method_definition_registry",
                  "CREATE TABLE method_templates"] {
            #expect(!schema.contains(t))
        }
    }

    @Test("No concrete Stage 4 method engine is declared in the Method subsystem")
    func noConcreteMethodEngine() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for concept in ["FiveWhys", "Fishbone", "HypothesisMatrix", "RootCauseAssessment",
                            "CAPA", "FMEA", "RiskMatrix", "DecisionMatrix", "ContradictionMatrix"] {
                #expect(!declaresType(text, concept), "\(name) declares '\(concept)'")
            }
        }
    }

    @Test("The lifecycle engine mutates no canonical ledger table and creates no Claim")
    func lifecycleEngineNoCanonicalMutation() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method/Lifecycle") {
            let code = codeOnly(text)
            for canonical in ["claims", "evidence_blocks", "source_versions", "events",
                              "entities", "relationships", "contradictions", "gap_nodes"] {
                for verb in ["INSERT INTO \(canonical)", "UPDATE \(canonical)", "DELETE FROM \(canonical)"] {
                    #expect(!code.contains(verb), "\(name) mutates canonical '\(canonical)'")
                }
            }
            for token in ["Claim(", "ClaimRepository", "insertClaim", "confirmFact"] {
                #expect(!code.contains(token), "\(name) creates a canonical fact ('\(token)')")
            }
        }
    }

    @Test("Validators hold no database or repository")
    func validatorsNoDatabaseRepository() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method/Validation") {
            let code = codeOnly(text)
            for token in ["Database", "MethodRunRepository", "db.exec", "db.query", "sqlite3_", "INSERT INTO"] {
                #expect(!code.contains(token), "\(name) references '\(token)'")
            }
        }
    }

    @Test("A method review remains human-only")
    func reviewsRemainHumanOnly() throws {
        let human = MethodReview(methodRunID: UUID(), reviewKey: "k", reviewedContentRevision: 1,
            action: .acceptForWorkflow, actorKind: .human, actorIdentifier: "r", reviewedAt: Date(timeIntervalSince1970: 0))
        try human.validate()
        let system = MethodReview(methodRunID: UUID(), reviewKey: "k", reviewedContentRevision: 1,
            action: .acceptForWorkflow, actorKind: .system, actorIdentifier: "s", reviewedAt: Date(timeIntervalSince1970: 0))
        #expect(throws: MethodContractError.reviewRequiresHumanActor) { try system.validate() }
    }

    @Test("The Method subsystem has no LLM, UI or network dependency")
    func noLLMUINetwork() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for token in ["import SwiftUI", "import AppKit", "URLSession", "http://", "https://",
                          "Ollama", "LLMClient", "prompt(", "AppState"] {
                #expect(!text.contains(token), "\(name) references '\(token)'")
            }
        }
    }

    @Test("The Stage-3 method executor bindings are unchanged (v1 + v2)")
    func stage3BindingsUnchanged() throws {
        let v1 = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        let v2 = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/RegisteredMethodStepExecutor.swift")
        #expect(v1.contains("executorVersion = WorkflowStepExecutorVersion(rawValue: \"1\")"))
        #expect(v2.contains("executorVersion = WorkflowStepExecutorVersion(rawValue: \"2\")"))
    }

    @Test("The PM-003 bridge file remains reference-envelope-only")
    func pm003BridgeReferenceOnly() throws {
        let text = try Self.source("Kalsmritikosh/Workflow/Execution/Bridges/WorkflowMethodResultBridge.swift")
        for concept in ["ProfessionalMethodDefinition", "MethodRun", "MethodNode", "MethodRunRepository"] {
            #expect(!declaresType(text, concept))
        }
    }
}
