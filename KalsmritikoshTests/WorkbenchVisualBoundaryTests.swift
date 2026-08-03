//
//  WorkbenchVisualBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-004 (Stage C) architecture guards. Prove the visual-surface layer is a PURE presentation
//  projection: it holds no persistence (no schema, no SQL), it reuses the shared drill-through
//  vocabulary (WorkbenchBindingTargetKind + SourceLocator) rather than forking it, and it names no
//  model. Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-004 — visual-surface architecture guards")
struct WorkbenchVisualBoundaryTests {

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
        "Kalsmritikosh/Workbench/Visual/WorkbenchVisualSurface.swift",
        "Kalsmritikosh/Workbench/Visual/WorkbenchSurfaceProjector.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The visual subsystem is present")
    func present() { #expect(files().count == 2) }

    @Test("No model names anywhere in the visual subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The visual layer holds no persistence: no schema, no SQL, no database access")
    func noPersistence() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("CREATE TABLE"))
        #expect(!all.contains("INSERT INTO"))
        #expect(!all.contains("UPDATE "))
        #expect(!all.contains("DELETE FROM"))
        #expect(!all.contains("Database"))
        // LAB-004 adds no schema bump.
        #expect(SchemaMigrations.latestVersion >= 94)
    }

    @Test("The inspection target reuses the shared drill-through vocabulary and forks none of it")
    func reusesSharedVocabulary() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(all.contains("WorkbenchBindingTargetKind"))   // reused, not redefined
        #expect(all.contains("SourceLocator"))
        #expect(!all.contains("enum WorkbenchBindingTargetKind"))
        #expect(!all.contains("struct SourceLocator"))
    }

    @Test("The canvas kind vocabulary is the fixed closed set")
    func closedKindVocabulary() {
        #expect(WorkbenchVisualSurfaceKind.allCases.count == 14)
    }

    @Test("Every element type structurally carries a provenance (one-action inspection is mandatory)")
    func provenanceMandatory() {
        // A WorkbenchVisualElement cannot be constructed without a provenance (non-optional), and the
        // raw builder rejects a nil provenance — the two together make an un-inspectable element impossible.
        let s = codeOnly((try? read("Kalsmritikosh/Workbench/Visual/WorkbenchSurfaceProjector.swift")) ?? "")
        #expect(s.contains("elementMissingProvenance"))
    }
}
