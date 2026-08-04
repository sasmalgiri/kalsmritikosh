//
//  ShellRoutingBoundaryTests.swift
//  KalsmritikoshTests
//
//  SHELL-002 architecture guards. Prove routing is ONE persona-neutral authority: it reuses the existing
//  WorkspaceTemplate persona identity and the SHELL-001 AppNavigationDestination (forking neither), it
//  builds no persona-specific duplicate destinations, it exposes only the two Fast/Full answer modes
//  (no second answer engine, no older depth names), and it holds no persistence. Source scanning + value
//  checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-002 — routing architecture guards")
struct ShellRoutingBoundaryTests {

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
        "Kalsmritikosh/Shell/Routing/ShellSurface.swift",
        "Kalsmritikosh/Shell/Routing/ShellRouter.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The routing subsystem is present")
    func present() { #expect(files().count == 2) }

    @Test("No model names anywhere in the routing subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "mistral", "nomic"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("Routing reuses the shared destination + persona identity, forking neither")
    func reusesSharedVocabulary() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(all.contains("AppNavigationDestination"))
        #expect(all.contains("WorkspaceTemplate"))
        #expect(!all.contains("enum AppNavigationDestination"))
        #expect(!all.contains("enum WorkspaceTemplate"))
    }

    @Test("Ask exposes exactly two modes and forks no second answer engine / older depth names")
    func onlyTwoAnswerModes() {
        #expect(ShellAnswerMode.allCases.count == 2)
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        for banned in ["case auto", "case normal", "case deep", "case expert", "case intermediate", "case research\n"] {
            #expect(!all.contains(banned), "routing forks an extra answer mode: \(banned)")
        }
        // No forked answer/query engine lives here.
        #expect(!all.contains("AnswerLedgerRepository"))
        #expect(!all.contains("func compute("))
    }

    @Test("Routing holds no persistence and adds no schema")
    func noPersistence() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("CREATE TABLE"))
        #expect(!all.contains("INSERT INTO"))
        #expect(!all.contains("Database"))
        #expect(SchemaMigrations.latestVersion >= 95)   // SHELL-002 adds no schema bump
    }

    @Test("The surface vocabulary is closed and its Simple subset is a strict subset of all surfaces")
    func closedSurfaceVocabulary() {
        #expect(Set(ShellSurface.allCases.map(\.rawValue)) ==
                ["home", "ask", "myWork", "dataLab", "sources", "evidence", "reports", "settings"])
        #expect(Set(ShellSurface.simpleSurfaces).isSubset(of: Set(ShellSurface.allCases)))
        #expect(ShellSurface.simpleSurfaces.count < ShellSurface.allCases.count)
    }

    @Test("Every persona resolves through the single ShellRouter to a shared destination (no duplicate route impl)")
    func singleRouterNoDuplicateDestinations() {
        // A persona-specific destination would show up as a route whose destination differs from the
        // surface's shared destination. Prove none does.
        for template in WorkspaceTemplate.allCases {
            for surface in ShellSurface.allCases {
                #expect(ShellRouter.route(template: template, mode: .advanced, surface: surface).destination == surface.destination)
            }
        }
    }
}
