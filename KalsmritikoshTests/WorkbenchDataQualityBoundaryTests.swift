//
//  WorkbenchDataQualityBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-005 (Stage C) architecture guards. Prove the data-quality layer is a PURE read-only analysis:
//  it never mutates canonical evidence or the dataset/scenario tables, it reuses the LAB-004 inspection
//  target (not a forked lineage type), its severities are a fixed property of the warning kind (not a
//  function of a confidence score), and it names no model. Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-005 — data-quality architecture guards")
struct WorkbenchDataQualityBoundaryTests {

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
        "Kalsmritikosh/Workbench/Quality/WorkbenchDataQuality.swift",
        "Kalsmritikosh/Workbench/Quality/WorkbenchDataQualityEvaluator.swift",
        "Kalsmritikosh/Workbench/Quality/WorkbenchDataQualityAnalyzer.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The data-quality subsystem is present")
    func present() { #expect(files().count == 3) }

    @Test("No model names anywhere in the data-quality subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The data-quality layer performs no mutation of canonical evidence or the workbench tables")
    func readOnly() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        for table in ["claims", "events", "entities", "evidence_blocks", "source_versions",
                      "workbench_cells", "workbench_scenarios", "workbench_scenario_operations"] {
            #expect(!all.contains("INSERT INTO \(table)"), "mutates \(table)")
            #expect(!all.contains("UPDATE \(table) "), "mutates \(table)")
            #expect(!all.contains("DELETE FROM \(table)"), "mutates \(table)")
        }
    }

    @Test("Warnings reuse the LAB-004 inspection target for lineage, not a forked type")
    func reusesInspectionTarget() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(all.contains("EvidenceInspectionTarget"))
        #expect(!all.contains("struct SourceLocator"))
    }

    @Test("Severity is a fixed property of the warning kind, not a function of a confidence score")
    func severityNotFromConfidence() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("ConfidenceEngine"))
        #expect(Set(WorkbenchQualitySeverity.allCases.map(\.rawValue)) == ["info", "caution", "blocking"])
    }

    @Test("The warning-kind vocabulary is the fixed closed set of 14 and adds no schema")
    func closedVocabularyNoSchema() {
        #expect(Set(WorkbenchQualityWarningKind.allCases.map(\.rawValue)) ==
                ["missingValue", "staleSourceVersion", "inaccessibleSource", "ambiguousIdentity", "mixedDatePrecision",
                 "unsupportedTransformation", "duplicateSource", "nonIndependentCorroboration", "missingCustodyHash",
                 "unresolvedContradiction", "incompleteWorkspaceScope", "unreviewedScenarioValue", "lowOCRConfidence", "formulaVsDisplayedDiscrepancy"])
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("CREATE TABLE"))
        #expect(SchemaMigrations.latestVersion >= 94)
    }
}
