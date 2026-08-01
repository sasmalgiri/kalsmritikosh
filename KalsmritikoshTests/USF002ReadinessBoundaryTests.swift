//
//  USF002ReadinessBoundaryTests.swift
//  KalsmritikoshTests
//
//  USF-002 — architectural guards. Readiness is keyed by the exact SourceVersion, introduces no
//  second source/version authority, derives the completion state (no direct writer), keeps
//  ParseCoverageReport/live progress/KnowledgeObject/Chunk as non-authorities, never changes a
//  Claim, and does no USF-003+ parser-registry work, no LLM/network, and no concrete method.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002 — readiness boundaries")
struct USF002ReadinessBoundaryTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }
    private func readinessSources() throws -> String {
        let dir = repoRoot().appendingPathComponent("Kalsmritikosh/Ingestion/Readiness")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    @Test("Readiness introduces no second source or version identity table")
    func noSecondSourceAuthority() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        // The only source-identity tables are files + source_versions.
        let names = try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%source%';", [])
            .compactMap { $0.string(0) }
        #expect(names.contains("source_versions"))
        #expect(names.contains("source_readiness_aggregates"))
        // No competing version authority: the readiness tables reference source_versions, never redefine it.
        let v85 = try readSource("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        #expect(v85.contains("REFERENCES source_versions(id) ON DELETE CASCADE"))
    }

    @Test("Readiness is keyed by the exact source version")
    func readinessKeyedBySourceVersion() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        let aggCols = try await db.query("PRAGMA table_info(source_readiness_aggregates);", []).compactMap { $0.string(1) }
        #expect(aggCols.contains("source_version_id"))
        // aggregate primary key is the source version id
        let pk = try await db.query("PRAGMA table_info(source_readiness_aggregates);", []).first { $0.int(5) == 1 }?.string(1)
        #expect(pk == "source_version_id")
    }

    @Test("There is no direct writer of the overall completion state")
    func noDirectCompletionStateWriter() async throws {
        // The aggregate table has NO completion-state column (it is derived).
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        let aggCols = try await db.query("PRAGMA table_info(source_readiness_aggregates);", []).compactMap { $0.string(1) }
        #expect(!aggCols.contains("completion_state"))
        // The repository never constructs a completion state — it writes dimensions + events and
        // lets the evaluator DERIVE the completion. Only the evaluator names SourceCompletionState.
        let repo = try readSource("Kalsmritikosh/Ingestion/Readiness/SourceReadinessRepository.swift")
        #expect(!repo.contains("SourceCompletionState"))
        let evaluator = try readSource("Kalsmritikosh/Ingestion/Readiness/SourceReadinessEvaluator.swift")
        #expect(evaluator.contains("SourceCompletionState"))
    }

    @Test("ParseCoverageReport is a projection, not an independent authority")
    func parseCoverageReportNotAuthority() throws {
        let src = try readSource("Kalsmritikosh/Ingestion/Structural/ParseCoverageReport.swift")
        #expect(src.contains("from(_ snapshot: SourceReadinessSnapshot"))
        #expect(src.contains("no longer an independent readiness authority"))
    }

    @Test("Live ingest progress is kept separate from durable readiness")
    func liveProgressNotReadiness() throws {
        let src = try readSource("Kalsmritikosh/UI/SourcesView.swift")
        #expect(src.contains("durableReadiness"))
        #expect(src.contains("LIVE ingest activity"))
        // AppState exposes the durable authority as a distinct method.
        let appState = try readSource("Kalsmritikosh/App/AppState.swift")
        #expect(appState.contains("func sourceReadinessSummary()"))
    }

    @Test("The readiness repository writes no KnowledgeObject or Chunk rows (they stay projections)")
    func koChunkStayProjections() throws {
        let src = try readSource("Kalsmritikosh/Ingestion/Readiness/SourceReadinessRepository.swift")
        #expect(!src.contains("INSERT INTO knowledge_objects"))
        #expect(!src.contains("INSERT INTO chunks"))
    }

    @Test("Readiness never writes a Claim or changes evidence status")
    func readinessNeverChangesClaims() throws {
        let all = try readinessSources()
        #expect(!all.contains("INSERT INTO claims"))
        #expect(!all.contains("UPDATE claims"))
        #expect(!all.contains("evidence_basis"))
    }

    @Test("Readiness does no parser-registry work and has no LLM/network dependency")
    func noParserRegistryOrLLMNetwork() throws {
        let all = try readinessSources()
        #expect(!all.contains("StructuralParserRegistry"))
        #expect(!all.contains("import SwiftUI"))
        #expect(!all.contains("URLSession"))
        #expect(!all.contains("LLMClient"))
    }

    @Test("Readiness introduces no concrete professional method")
    func noConcreteMethod() throws {
        let all = try readinessSources()
        for token in ["struct FiveWhys", "struct Fishbone", "struct CAPA", "class FiveWhys", "enum Fishbone"] {
            #expect(!all.contains(token))
        }
    }
}
