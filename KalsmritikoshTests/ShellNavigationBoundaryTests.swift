//
//  ShellNavigationBoundaryTests.swift
//  KalsmritikoshTests
//
//  SHELL-001 architecture guards. Prove the shell's Back/Forward LOCATION history is DISTINCT from
//  workflow Prev/Next: the navigation model has no coupling to workflow runs or steps. Also prove it
//  names no model, adds exactly one schema bump (v95), and reuses a closed destination vocabulary.
//  Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-001 — navigation architecture guards")
struct ShellNavigationBoundaryTests {

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
        "Kalsmritikosh/Shell/Navigation/AppNavigationHistory.swift",
        "Kalsmritikosh/Shell/Navigation/ShellSessionRepository.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The shell navigation subsystem is present")
    func present() { #expect(files().count == 2) }

    @Test("No model names anywhere in the shell navigation subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("Location Back/Forward is distinct from workflow Prev/Next — no coupling to workflow runs or steps")
    func distinctFromWorkflowStepping() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("WorkflowRun"))
        #expect(!all.contains("WorkflowStep"))
        #expect(!all.contains("MethodRun"))
        #expect(all.contains("AppNavigationDestination"))   // it is a LOCATION history
    }

    @Test("The navigation layer touches no canonical evidence")
    func noCanonicalMutation() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        for table in ["claims", "events", "entities", "evidence_blocks", "source_versions", "workbench_cells"] {
            #expect(!all.contains("INSERT INTO \(table)"))
            #expect(!all.contains("UPDATE \(table) "))
            #expect(!all.contains("DELETE FROM \(table)"))
        }
    }

    @Test("The destination vocabulary is the fixed closed set")
    func closedDestinationVocabulary() {
        #expect(Set(AppNavigationDestination.allCases.map(\.rawValue)) ==
                ["home", "sources", "timeline", "entities", "relationships", "dataLab", "methods", "jobs", "answers", "reports", "evidenceInspector", "settings"])
    }

    @Test("SHELL-001 adds exactly one schema bump: latest is >= v95 and the tables are created once")
    func oneSchemaBump() throws {
        #expect(SchemaMigrations.latestVersion >= 95)
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for table in ["app_navigation_sessions", "app_navigation_entries"] {
            #expect(migrations.components(separatedBy: "CREATE TABLE \(table) (").count == 2, "\(table) not created exactly once")
        }
    }

    @Test("The v95 navigation migration suite is registered in the migration matrix")
    func migrationSuiteRegistered() throws {
        #expect(try read("ci/test-groups/migration-matrix.json").contains("ShellSessionMigrationTests"))
    }
}
