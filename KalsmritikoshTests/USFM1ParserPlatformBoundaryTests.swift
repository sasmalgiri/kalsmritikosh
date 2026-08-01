//
//  USFM1ParserPlatformBoundaryTests.swift
//  KalsmritikoshTests
//
//  USF-M1 §25 — architecture guards proving the platform's invariants by scanning committed source.
//  The production ingest path dispatches through the ONE UniversalParserRegistry and never consults
//  the old LoaderRegistry / StructuralParserRegistry independently; content surfaces are NOT a second
//  readiness system; no parser mutates Claims or method/workflow tables; and the parser subsystem
//  makes no network / LLM call and names no model. Synthetic reasoning over the repo, no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M1 — parser platform architecture guards")
struct USFM1ParserPlatformBoundaryTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }
    /// Every Swift file in the parser subsystem, concatenated.
    private func parsingSources() throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent("Kalsmritikosh/Ingestion/Parsing")
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
    private func coordinator() throws -> String {
        try read("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift")
    }

    // MARK: - One routing authority

    @Test("IngestCoordinator no longer consults the old LoaderRegistry / StructuralParserRegistry")
    func coordinatorDoesNotConsultOldRegistries() throws {
        let src = try coordinator()
        #expect(!src.contains("LoaderRegistry"))
        #expect(!src.contains("StructuralParserRegistry"))
        #expect(!src.contains("structuralRegistry"))
        #expect(!src.contains("loaders.loader(for"))
        #expect(!src.contains(".parser(for:"))
    }

    @Test("IngestCoordinator dispatches through the universal executor + registry only")
    func coordinatorRoutesThroughUniversalExecutor() throws {
        let src = try coordinator()
        #expect(src.contains("universalExecutor"))
        #expect(src.contains("universalExecutor.execute"))
        #expect(src.contains("registry.resolve"))
    }

    @Test("IngestCoordinator does not run loaders directly — loader/structural execution lives in the adapter")
    func coordinatorDoesNotRunLoadersDirectly() throws {
        let src = try coordinator()
        #expect(!src.contains("loader.ingestMany"))
        #expect(!src.contains("loader.ingest("))
        #expect(!src.contains("structural.parse("))
    }

    @Test("AppState constructs the ONE universal registry and injects it into the coordinator")
    func appStateConstructsRegistryOnce() throws {
        let src = try read("Kalsmritikosh/App/AppState.swift")
        #expect(src.contains("UniversalParserRegistryBuilder.standard"))
        #expect(src.contains("universalRegistry:"))
        #expect(!src.contains("loaders: .standard()"))
        #expect(!src.contains("structuralRegistry: .standard"))
    }

    // MARK: - Surfaces are not a second readiness system

    @Test("Content-surface coverage is a minimal advisory vocabulary, not a readiness state")
    func surfaceCoverageIsNotReadiness() throws {
        let src = try read("Kalsmritikosh/Ingestion/Parsing/ContentSurface.swift")
        #expect(src.contains("case complete"))
        #expect(src.contains("case partial"))
        #expect(src.contains("case notApplicable"))
        #expect(!src.contains("case ready"))
        #expect(!src.contains("case blocked"))
        #expect(!src.contains("case unsupported"))
    }

    @Test("No parser plugin declares durable readiness (that derives only from committed proof)")
    func noPluginDeclaresDurableReadiness() throws {
        for (name, text) in try parsingSources() {
            #expect(!text.contains("isEvidenceReady"), "\(name) must not declare readiness")
            #expect(!text.contains("isSearchReady"), "\(name) must not declare readiness")
            #expect(!text.contains("isAnalyticallyReady"), "\(name) must not declare readiness")
        }
    }

    // MARK: - Parsers do not reach beyond parsing

    @Test("No parser subsystem file creates/mutates Claims or writes method/workflow tables")
    func noParserMutatesClaimsOrMethodTables() throws {
        for (name, text) in try parsingSources() {
            #expect(!text.contains("INSERT INTO"), "\(name) must not write to the ledger")
            #expect(!text.contains("ClaimRepository"), "\(name) must not touch claims")
            #expect(!text.contains("method_run"), "\(name) must not touch method tables")
        }
    }

    @Test("No parser subsystem file makes a network call or resolves an LLM capability")
    func noParserNetworkOrLLM() throws {
        for (name, text) in try parsingSources() {
            #expect(!text.contains("URLSession"), "\(name) must not open a network session")
            #expect(!text.contains("https://"), "\(name) must not embed a URL endpoint")
            #expect(!text.contains("capabilities.resolve"), "\(name) must not resolve a model capability")
        }
    }

    @Test("Grep guard — no model names anywhere in the parser subsystem")
    func grepGuardNoModelNamesInParsing() throws {
        let forbidden = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in try parsingSources() {
            let lower = text.lowercased()
            for token in forbidden {
                #expect(!lower.contains(token), "\(name) must not name model '\(token)'")
            }
        }
    }
}
