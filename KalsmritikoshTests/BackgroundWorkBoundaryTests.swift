//
//  BackgroundWorkBoundaryTests.swift
//  KalsmritikoshTests
//
//  SHELL-003 architecture guards. Prove there is ONE background-work authority: the gate composes the
//  EXISTING QueryPriorityGate + SystemActivity rather than forking a second scheduler, background work
//  can never outrank foreground user work, the layer holds no persistence, and it names no model.
//  Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-003 — background-work architecture guards")
struct BackgroundWorkBoundaryTests {

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
    private let rels = [
        "Kalsmritikosh/Shell/Background/BackgroundWorkPolicy.swift",
        "Kalsmritikosh/Shell/Background/BackgroundWorkGate.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The background-work subsystem is present")
    func present() { #expect(files().count == 2) }

    @Test("No model names anywhere in the background-work subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "mistral", "nomic"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The gate composes the EXISTING QueryPriorityGate + SystemActivity, forking no second scheduler")
    func composesExistingInfra() {
        let gate = codeOnly((try? read("Kalsmritikosh/Shell/Background/BackgroundWorkGate.swift")) ?? "")
        #expect(gate.contains("QueryPriorityGate"))
        #expect(gate.contains("SystemActivity"))
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("class BackgroundTaskScheduler"))   // no forked scheduler
        #expect(!all.contains("Scheduler"))
    }

    @Test("Background work can never outrank foreground user work (P0–P4 always permitted; P5–P6 gated)")
    func backgroundNeverOutranksForeground() {
        let hostile = BackgroundWorkInputs(preference: BackgroundWorkPreference(enabled: true, trigger: .idle),
                                           now: Date(timeIntervalSinceReferenceDate: 0), idleSeconds: 0,
                                           isInteractiveActive: true, activeWorkPriorities: [.uiInteraction])
        for p in [BackgroundWorkPriority.uiInteraction, .askSearchDataLab, .fullEvidence, .jobWorkflow, .ingestion] {
            #expect(BackgroundWorkPolicy.permits(p, inputs: hostile))
        }
        #expect(!BackgroundWorkPolicy.permits(.requiredDeferred, inputs: hostile))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: hostile))
    }

    @Test("The background-work layer holds no persistence and adds no schema")
    func noPersistence() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("CREATE TABLE"))
        #expect(!all.contains("INSERT INTO"))
        #expect(!all.contains("Database"))
        #expect(SchemaMigrations.latestVersion >= 95)   // SHELL-003 adds no schema bump
    }

    @Test("The priority ladder + trigger vocabularies are the fixed closed sets")
    func closedVocabularies() {
        #expect(Set(BackgroundWorkPriority.allCases.map(\.rawValue)) == Set(0...6))
        #expect(Set(BackgroundWorkTrigger.allCases.map(\.rawValue)) == ["idle", "offHours"])
    }
}
