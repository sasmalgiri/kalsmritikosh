//
//  WorkbenchModeBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-006 (Stage C closure) architecture guards. Prove Simple/Advanced is a PRESENTATION policy, not a
//  second engine or store: the mode layer holds no persistence and no schema, it reuses the ONE
//  WorkbenchDatasetMode, the ONE LAB-002 transform spec, and the ONE LAB-005 report / LAB-004 surface —
//  it defines no competing dataset-mode enum, no transform engine, and no repository. Source scanning +
//  value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-006 — mode architecture guards")
struct WorkbenchModeBoundaryTests {

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
        "Kalsmritikosh/Workbench/Mode/WorkbenchModePolicy.swift",
        "Kalsmritikosh/Workbench/Mode/WorkbenchModePresentation.swift",
        "Kalsmritikosh/Workbench/Mode/WorkbenchModePresetCatalog.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The mode subsystem is present")
    func present() { #expect(files().count == 3) }

    @Test("No model names anywhere in the mode subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The mode layer holds no persistence and adds no schema")
    func noPersistenceNoSchema() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("CREATE TABLE"))
        #expect(!all.contains("INSERT INTO"))
        #expect(!all.contains("UPDATE "))
        #expect(!all.contains("DELETE FROM"))
        #expect(!all.contains("Database"))
        #expect(SchemaMigrations.latestVersion >= 94)   // LAB-006 adds no schema bump
    }

    @Test("The mode layer forks no second dataset-mode, transform engine, scenario engine or repository")
    func noSecondAuthority() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("enum WorkbenchDatasetMode"))       // reuses the ONE dataset-mode
        #expect(!all.contains("actor "))                          // no repository / persistence actor
        #expect(!all.contains("func compute("))                  // no forked transform engine
        #expect(!all.contains("func evaluate("))                 // no forked evaluator
    }

    @Test("Simple calculations reuse the ONE LAB-002 transform spec, not a separate easy-mode calculator")
    func simpleReusesTransformSpec() throws {
        let catalog = codeOnly(try read("Kalsmritikosh/Workbench/Mode/WorkbenchModePresetCatalog.swift"))
        #expect(catalog.contains("WorkbenchTransformSpec"))
        #expect(catalog.contains(".aggregate(") && catalog.contains(".filter(") && catalog.contains(".sort("))
    }

    @Test("Presentation slices the ONE report / surface, reusing the shared quality + visual types")
    func presentationReusesSharedTypes() throws {
        let p = codeOnly(try read("Kalsmritikosh/Workbench/Mode/WorkbenchModePresentation.swift"))
        #expect(p.contains("WorkbenchDataQualityReport"))
        #expect(p.contains("WorkbenchVisualSurface"))
        #expect(!p.contains("struct WorkbenchDataQualityReport"))   // reused, not redefined
    }
}
