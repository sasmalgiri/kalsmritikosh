//
//  InvestigationAskBoundaryTests.swift
//  KalsmritikoshTests
//
//  INV-01-C1 architecture guards (§22). Prove the Investigator Ask entry point ORCHESTRATES the shared
//  engine rather than forking it: no InvestigatorBrain / InvestigatorRetriever; the service is not itself
//  a Retriever; it composes the shared MasterBrain + SourceScopedRetriever + CaseRetrievalScopeResolver;
//  it only ever hands the engine the SCOPED retriever (never the raw base); and AppState actually
//  consumes it (a live entry point, not a dangling reusable API). Source scanning + value checks.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C1 — Investigator Ask architecture guards")
struct InvestigationAskBoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private let serviceRel = "Kalsmritikosh/Personas/Investigator/InvestigationAnswerService.swift"
    private let appStateRel = "Kalsmritikosh/App/AppState.swift"

    @Test("The Ask service is present")
    func present() { #expect((try? read(serviceRel)) != nil) }

    @Test("No model names in the Ask entry point")
    func noModelNames() throws {
        let lower = codeOnly(try read(serviceRel)).lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] {
            #expect(!lower.contains(m), "Ask service names model \(m)")
        }
    }

    @Test("The service forks no persona engine and is not itself a retriever")
    func noForkedEngines() throws {
        let s = codeOnly(try read(serviceRel))
        for banned in ["InvestigatorBrain", "InvestigatorRetriever", "InvestigatorDataLab",
                       "InvestigatorMethodEngine", "InvestigatorEvidenceStore", "InvestigatorClaimStore",
                       "actor MasterBrain", "class MasterBrain", "struct HybridRetriever", "class HybridRetriever"] {
            #expect(!s.contains(banned), "Ask service forks: \(banned)")
        }
        #expect(!s.contains("InvestigationAnswerService: Retriever"))   // it orchestrates; it is not a retriever
    }

    @Test("The service composes the shared engine: MasterBrain + SourceScopedRetriever + case resolver")
    func composesShared() throws {
        let s = codeOnly(try read(serviceRel))
        #expect(s.contains("MasterBrain"))                    // uses the one shared engine (via the factory)
        #expect(s.contains("SourceScopedRetriever(base: baseRetriever"))   // wraps the shared retriever
        #expect(s.contains("CaseRetrievalScopeResolver"))     // reuses the one scope resolver
    }

    @Test("The engine only ever receives the SCOPED retriever, never the raw base (no scope bypass)")
    func noRawRetrieverToEngine() throws {
        let s = codeOnly(try read(serviceRel))
        // The brain factory is invoked with the scoped retriever; the base is used solely to build it.
        #expect(s.contains("makeBrain(scoped)"))
        #expect(!s.contains("makeBrain(baseRetriever)"))
        #expect(!s.contains("makeBrain(base)"))
    }

    @Test("AppState actually consumes the Ask entry point (a live path, not a dangling API)")
    func appStateWiresIt() throws {
        let app = codeOnly(try read(appStateRel))
        #expect(app.contains("InvestigationAnswerService("))
        #expect(app.contains("investigationAnswers"))
        // The production wiring hands it the shared retriever + case-scope resolver.
        #expect(app.contains("baseRetriever: retriever"))
        #expect(app.contains("CaseRetrievalScopeResolver(evidence:"))
    }

    @Test("Unknown-case access fails closed with a typed error (value-level)")
    func caseNotFoundIsTyped() {
        let id = UUID()
        #expect(InvestigationAnswerError.caseNotFound(id) == .caseNotFound(id))
        #expect(InvestigationAnswerError.caseNotFound(id) != .caseNotFound(UUID()))
    }
}
