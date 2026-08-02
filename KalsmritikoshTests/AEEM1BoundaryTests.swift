//
//  AEEM1BoundaryTests.swift
//  KalsmritikoshTests
//
//  AEE-M1 architecture guards — the mission layer COMPOSES the existing authorities and
//  introduces no competing one: no second readiness/completion/query-plan/trace/
//  sufficiency system, no competing lane vocabulary, no persistence, no schema change,
//  no model names, no AEE-M2 progressive-answer states, no concrete professional method.
//  The planner decides; it never executes. Source scanning — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M1 — architecture guards")
struct AEEM1BoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func aeeFiles() -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent("Kalsmritikosh/Brain/AEE")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
            .compactMap { u in (try? String(contentsOf: u, encoding: .utf8)).map { (u.lastPathComponent, $0) } }
    }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    @Test("The AEE subsystem is present")
    func present() {
        #expect(aeeFiles().count >= 9)
    }

    @Test("AEE declares no second readiness / completion / query-plan / trace / sufficiency authority")
    func noDuplicateAuthorities() {
        let banned = ["enum SourceCompletionState", "struct SourceReadinessSnapshot",
                      "struct QueryPlan", "struct ReasoningTrace", "struct EvidenceSufficiency",
                      "enum SourceReadinessDimension"]
        for (name, text) in aeeFiles() {
            let code = codeOnly(text)
            for token in banned { #expect(!code.contains(token), "\(name) redeclares \(token)") }
        }
    }

    @Test("AEE declares no competing lane/tier vocabulary")
    func noCompetingLaneVocabulary() {
        let banned = ["case simple", "case normal", "case advanced", "case smart", "case agentic", "case deepAI"]
        for (name, text) in aeeFiles() {
            let code = codeOnly(text)
            for token in banned { #expect(!code.contains(token), "\(name) introduces competing tier \(token)") }
        }
    }

    @Test("AEE adds no persistence — no tables, no SQL writes")
    func noPersistence() {
        for (name, text) in aeeFiles() {
            let code = codeOnly(text)
            #expect(!code.contains("CREATE TABLE"), "\(name) creates a table")
            #expect(!code.contains("INSERT INTO"), "\(name) writes SQL")
        }
    }

    @Test("The AdaptiveEvidencePlanner decides but never executes an upgrade")
    func plannerDecidesOnly() throws {
        let planner = try read("Kalsmritikosh/Brain/AEE/AdaptiveEvidencePlanner.swift")
        let code = codeOnly(planner)
        // The planner's plan() is pure/synchronous — it never calls the bridge's ensureReady.
        #expect(!code.contains(".ensureReady("), "the planner must not execute upgrades")
        #expect(code.contains("func plan("))
    }

    @Test("AEE introduces no second MasterBrain and no concrete professional method")
    func noSecondBrainOrMethod() {
        let banned = ["actor MasterBrain", "class MasterBrain", "struct FiveWhys", "struct Fishbone",
                      "class CAPA", "AdaptiveEvidenceEngine"]
        for (name, text) in aeeFiles() {
            for token in banned { #expect(!text.contains(token), "\(name) must not declare \(token)") }
        }
    }

    @Test("The AEE-M1 mission/lane files carry no AEE-M2 progressive-answer states")
    func noProgressiveAnswerStates() {
        // AEE-M2 landed the progressive lifecycle in its OWN files (ProgressiveAnswer*.swift);
        // this guard ensures those states did not leak into the M1 mission/lane orchestration.
        let m2 = ["immediateFinding", "groundedWorkingResult", "analysisProgress", "reviewReady", "verifiedFinal"]
        let m1Only = aeeFiles().filter { !$0.name.hasPrefix("ProgressiveAnswer") }
        for (name, text) in m1Only {
            for token in m2 { #expect(!text.contains(token), "\(name) introduces M2 state \(token)") }
        }
    }

    @Test("No model names anywhere in AEE; schema is at least v89 (AEE-M2 revision ledger)")
    func grepGuardAndSchema() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in aeeFiles() {
            let lower = text.lowercased()
            for token in models { #expect(!lower.contains(token), "\(name) names model \(token)") }
        }
        #expect(SchemaMigrations.latestVersion >= 89)   // AEE-M2 added the answer-revision ledger; later units bump higher
    }
}
