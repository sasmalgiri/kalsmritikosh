//
//  PJE006CScopeGuardTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — scope guards: no Stage 4 method engine, no second work-product
//  route/store, repository-free executors, no live catalog, no network, and
//  executable Stage 3 coverage for all 17 step kinds. 6 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — Scope guards")
struct PJE006CScopeGuardTests {

    // MARK: - Source access (repo-relative from this file's compile-time path)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)               // …/KalsmritikoshTests/PJE006CScopeGuardTests.swift
            .deletingLastPathComponent()              // …/KalsmritikoshTests
            .deletingLastPathComponent()              // repo root
    }

    private static var executorsDir: URL {
        repoRoot.appendingPathComponent("Kalsmritikosh/Workflow/Execution/Executors")
    }

    private static func sources(in dir: URL) throws -> [(name: String, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("Executor files hold no Database, Repository, or work-product service dependencies")
    func executorsAreRepositoryFree() throws {
        let banned = ["Database", "Repository", "WorkProductAssemblyService",
                      "WorkProductRunRepository"]
        for (name, text) in try Self.sources(in: Self.executorsDir) {
            for token in banned {
                #expect(!text.contains(token),
                        "\(name) must not reference \(token) — only bridge/coordinator files may")
            }
        }
    }

    @Test("No Stage 4 method engine types or tables were introduced")
    func noStageFourMethodEngine() throws {
        let workflowDir = Self.repoRoot.appendingPathComponent("Kalsmritikosh/Workflow")
        // Declaration tokens only — boundary DOCUMENTATION may name these concepts,
        // but no Stage 4 TYPE may be declared.
        let bannedDecls = [
            "struct ProfessionalMethodDefinition", "class ProfessionalMethodDefinition",
            "struct MethodRun", "class MethodRun", "actor MethodRun",
            "struct MethodNode", "struct MethodEdge",
            "struct FiveWhys", "enum FiveWhys", "struct Fishbone", "enum Fishbone",
            "struct CAPA", "enum CAPA", "struct DecisionMatrix", "enum DecisionMatrix"
        ]
        let enumerator = FileManager.default.enumerator(at: workflowDir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in bannedDecls {
                #expect(!text.contains(token),
                        "\(url.lastPathComponent) must not declare Stage 4 type \(token)")
            }
        }
        // No Stage-4 method-DEFINITION table in any migration (the Stage-4 run-state
        // ledger `method_runs` is owned by PM-002 / schema v79 under Method/Persistence;
        // definitions stay code-registry-backed, so no definition table exists).
        let schema = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Kalsmritikosh/Storage/Schema/SchemaMigrations.swift"),
            encoding: .utf8)
        #expect(!schema.contains("CREATE TABLE professional_method"))
    }

    @Test("No second work-product persistence store: coordinator path and standalone save share ONE writer")
    func oneSharedWorkProductWriter() throws {
        let repoFile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Kalsmritikosh/Storage/Repositories/WorkProductRunRepository.swift"),
            encoding: .utf8)
        let workflowRepoFile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Kalsmritikosh/Storage/Repositories/WorkflowRunRepository.swift"),
            encoding: .utf8)
        #expect(repoFile.contains("WorkProductRunPersistenceWriter.insert"),
                "Standalone save must use the shared writer")
        #expect(workflowRepoFile.contains("WorkProductRunPersistenceWriter.insert"),
                "Coordinated build must use the shared writer")
        // The INSERT INTO work_product_runs SQL exists in exactly one place: the writer.
        for (path, text) in [("WorkProductRunRepository.swift", repoFile),
                             ("WorkflowRunRepository.swift", workflowRepoFile)] {
            #expect(!text.contains("INSERT INTO work_product_runs"),
                    "\(path) must not duplicate the work-product INSERT SQL")
        }
    }

    @Test("Executors and the execution engine perform no live persona-catalog lookups")
    func noLiveCatalogLookup() throws {
        var files = try Self.sources(in: Self.executorsDir)
        let engineURL = Self.repoRoot.appendingPathComponent(
            "Kalsmritikosh/Workflow/Execution/WorkflowStepExecutionEngine.swift")
        files.append(("WorkflowStepExecutionEngine.swift",
                      try String(contentsOf: engineURL, encoding: .utf8)))
        for (name, text) in files {
            #expect(!text.contains("PersonaJobCatalog"),
                    "\(name) must not consult the live persona catalog")
        }
    }

    @Test("No network access or UI/AppState wiring in the Stage 3 execution layer")
    func noNetworkOrUIWiring() throws {
        let executionDir = Self.repoRoot.appendingPathComponent("Kalsmritikosh/Workflow/Execution")
        let banned = ["URLSession", "import SwiftUI", "AppState"]
        let enumerator = FileManager.default.enumerator(at: executionDir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in banned {
                #expect(!text.contains(token),
                        "\(url.lastPathComponent) must not reference \(token)")
            }
        }
    }

    @Test("All 17 shared step kinds resolve to an executable Stage 3 executor")
    func allSeventeenKindsCovered() throws {
        let registry = try PJE006CFixtures.makeFullRegistry(gate: FixtureEvidenceGate())
        #expect(WorkflowStepKind.allCases.count == 17)
        for kind in WorkflowStepKind.allCases {
            let executor = registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: kind)
            #expect(executor != nil, "No executor bound for step kind '\(kind.rawValue)'")
            #expect(executor?.handledKind == kind)
        }
    }
}
