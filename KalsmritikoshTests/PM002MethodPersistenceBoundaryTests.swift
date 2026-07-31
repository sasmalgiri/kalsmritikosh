//
//  PM002MethodPersistenceBoundaryTests.swift
//  KalsmritikoshTests
//
//  PM-002 — architecture guards: Stage 4 persistence stays under Method/, uses
//  ONE authoritative writer, mutates no canonical ledger, adds no concrete method
//  or second evidence-status system, and leaves the Stage 3 method adapter
//  untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-002 — method persistence boundary guards")
struct PM002MethodPersistenceBoundaryTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func declaresType(_ text: String, _ concept: String) -> Bool {
        text.range(of: "(struct|class|enum|actor|protocol)\\s+\(concept)\\b", options: .regularExpression) != nil
    }

    // MARK: - Placement

    @Test("Stage 4 method persistence types are declared only under Kalsmritikosh/Method/")
    func persistenceLivesUnderMethod() throws {
        // The repository/aggregate/error types must not be declared inside Stage 3 dirs.
        for dir in ["Kalsmritikosh/Workflow", "Kalsmritikosh/Storage", "Kalsmritikosh/Core/Models"] {
            for (name, text) in try Self.swiftFiles(under: dir) {
                for concept in ["MethodRunRepository", "MethodRunAggregate", "MethodPersistenceError"] {
                    #expect(!declaresType(text, concept), "\(name) must not declare Stage 4 type '\(concept)'")
                }
            }
        }
        // And they DO live under Method/Persistence.
        let repo = try Self.source("Kalsmritikosh/Method/Persistence/MethodRunRepository.swift")
        #expect(declaresType(repo, "MethodRunRepository"))
    }

    // MARK: - One authoritative writer

    @Test("Only MethodRunRepository writes the method tables (one authoritative writer)")
    func oneAuthoritativeWriter() throws {
        // The authoritative operational writer is the MethodRunRepository type; PM-004
        // adds its lifecycle writes in a same-type extension file
        // (MethodRunRepository+Lifecycle.swift). SchemaMigrations.swift is excluded: its
        // only method-table writes are the v80 rebuild's data-copy DDL (schema evolution,
        // not an operational writer).
        let authoritative: Set<String> = ["MethodRunRepository.swift", "MethodRunRepository+Lifecycle.swift",
                                          "SchemaMigrations.swift"]
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh") {
            guard !authoritative.contains(name) else { continue }
            for stmt in ["INSERT INTO method_", "UPDATE method_", "DELETE FROM method_"] {
                #expect(!text.contains(stmt), "\(name) must not write method tables ('\(stmt)')")
            }
        }
        let repo = try Self.source("Kalsmritikosh/Method/Persistence/MethodRunRepository.swift")
        #expect(repo.contains("INSERT INTO method_runs"))
    }

    // MARK: - No canonical mutation

    @Test("The method persistence layer mutates no canonical ledger table")
    func noCanonicalMutation() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for canonical in ["claims", "evidence_blocks", "source_versions", "events",
                              "entities", "relationships", "contradictions", "gap_nodes"] {
                for verb in ["INSERT INTO \(canonical)", "UPDATE \(canonical)", "DELETE FROM \(canonical)"] {
                    #expect(!text.contains(verb), "\(name) must not mutate canonical '\(canonical)'")
                }
            }
            for token in ["Claim(", "ClaimRepository", "insertClaim", "confirmFact", "GenericFact("] {
                #expect(!text.contains(token), "\(name) must not create a canonical fact ('\(token)')")
            }
        }
    }

    // MARK: - No concrete method, LLM, network, UI, or second evidence system

    @Test("The method subsystem declares no concrete Stage 4 method engine")
    func noConcreteMethodEngine() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for concept in ["FiveWhys", "Fishbone", "HypothesisMatrix", "RootCauseAssessment",
                            "CAPA", "RiskMatrix", "DecisionMatrix", "ContradictionMatrix"] {
                #expect(!declaresType(text, concept), "\(name) must not declare concrete method '\(concept)'")
            }
        }
    }

    @Test("The method subsystem has no LLM, network, UI or AppState dependency")
    func noLLMNetworkUI() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for token in ["import SwiftUI", "import AppKit", "URLSession", "http://", "https://",
                          "Ollama", "LLMClient", "prompt(", "AppState"] {
                #expect(!text.contains(token), "\(name) must not reference '\(token)'")
            }
        }
    }

    @Test("The method subsystem declares no second evidence-status vocabulary")
    func noSecondEvidenceStatusEnum() throws {
        for (name, text) in try Self.swiftFiles(under: "Kalsmritikosh/Method") {
            for evidenceType in ["EvidenceStatus", "FactStatus", "EvidenceAssessment",
                                 "ReviewDisposition", "EvidenceBasis"] {
                #expect(!declaresType(text, evidenceType),
                        "\(name) must not redeclare evidence-status type '\(evidenceType)'")
            }
        }
    }

    // MARK: - Aggregate is a single snapshot

    @Test("aggregate reconstruction reads one isolated database snapshot, not separate awaited reads")
    func aggregateIsSingleSnapshot() throws {
        let repo = try Self.source("Kalsmritikosh/Method/Persistence/MethodRunRepository.swift")
        let start = try #require(repo.range(of: "func aggregate(runID:"))
        let body = String(repo[start.lowerBound...].prefix(1600))
        // The run + all seven child reads happen inside ONE withSavepoint closure,
        // never through multiple separately-awaited read helpers.
        #expect(body.contains("withSavepoint"))
        for awaited in ["try await nodes(runID", "try await edges(runID", "try await findings(runID"] {
            #expect(!body.contains(awaited),
                    "aggregate must not reassemble via separately-awaited reads ('\(awaited)')")
        }
    }

    // MARK: - Stage 3 adapter untouched

    @Test("The Stage 3 MethodStepExecutor references no Stage 4 persistence type")
    func stage3ExecutorUntouched() throws {
        let executor = try Self.source("Kalsmritikosh/Workflow/Execution/Executors/MethodStepExecutor.swift")
        for token in ["MethodRunRepository", "MethodRun", "MethodNode", "MethodFinding",
                      "method_runs", "MethodRunAggregate"] {
            #expect(!executor.contains(token), "MethodStepExecutor must stay a generic adapter (no '\(token)')")
        }
    }

    // MARK: - No method tables on the Stage 3 workflow core

    @Test("Workflow core tables carry no method aggregate columns")
    func workflowCoreHasNoMethodColumns() throws {
        let schema = try Self.source("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        // method_run_id/method_node_id etc. must never appear as workflow-table columns.
        for token in ["ALTER TABLE workflow_runs ADD COLUMN method_",
                      "ALTER TABLE workflow_step_runs ADD COLUMN method_"] {
            #expect(!schema.contains(token), "workflow core must not gain method columns ('\(token)')")
        }
    }
}
