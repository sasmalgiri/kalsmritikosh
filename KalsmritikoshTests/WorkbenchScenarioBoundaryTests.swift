//
//  WorkbenchScenarioBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-003 (Stage C) architecture guards. Prove the scenario overlay keeps its promises at the SOURCE
//  level: it never mutates canonical evidence or source-derived cells (read-only isolation), it does
//  NOT fork a second transformation engine (it reuses WorkbenchTransformEngine) or a second privacy
//  authority (it composes SensitiveScopeRepository), and it has NO makeCanonical() / direct
//  claim/method-run write that would bypass established review. Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-003 — scenario architecture guards")
struct WorkbenchScenarioBoundaryTests {

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
        "Kalsmritikosh/Workbench/Scenario/WorkbenchScenario.swift",
        "Kalsmritikosh/Workbench/Scenario/WorkbenchScenarioProjection.swift",
        "Kalsmritikosh/Workbench/Scenario/WorkbenchScenarioRepository.swift",
        "Kalsmritikosh/Workbench/Scenario/WorkbenchScenarioSensitivity.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The scenario subsystem is present")
    func present() { #expect(files().count == 4) }

    @Test("No model names anywhere in the scenario subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The scenario layer never mutates canonical evidence or the dataset's source cells")
    func canonicalReadOnly() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        // Canonical evidence tables.
        for table in ["claims", "events", "entities", "evidence_blocks", "source_versions", "contradictions", "gap_nodes", "knowledge_objects"] {
            #expect(!all.contains("INSERT INTO \(table)"), "mutates canonical \(table)")
            #expect(!all.contains("UPDATE \(table) "), "mutates canonical \(table)")
            #expect(!all.contains("DELETE FROM \(table)"), "mutates canonical \(table)")
        }
        // The LAB-001/002 dataset tables the scenario reads but must not write.
        for table in ["workbench_cells", "workbench_fields", "workbench_rows", "workbench_transformations", "workbench_derivations"] {
            #expect(!all.contains("INSERT INTO \(table)"), "scenario writes \(table)")
            #expect(!all.contains("UPDATE \(table) "), "scenario writes \(table)")
            #expect(!all.contains("DELETE FROM \(table)"), "scenario writes \(table)")
        }
    }

    @Test("The scenario layer reuses the ONE transform engine and forks no second evaluator")
    func noSecondTransformEngine() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(all.contains("WorkbenchTransformEngine.compute"), "does not reuse the shared engine")
        #expect(!all.contains("enum WorkbenchExpr"), "forks an expression AST")
        #expect(!all.contains("struct RecursiveDescent"), "forks a parser")
        #expect(!all.contains("NSExpression"))
    }

    @Test("The scenario layer composes the shared SensitiveScope authority, not a forked one")
    func sharedSensitiveScope() throws {
        let s = codeOnly(try read("Kalsmritikosh/Workbench/Scenario/WorkbenchScenarioSensitivity.swift"))
        #expect(s.contains("SensitiveScopeRepository"))
        #expect(!s.contains("enum ProtectionLabel"))
        #expect(!s.contains("enum SensitivityLevel"))
    }

    @Test("Promotion cannot bypass review: no makeCanonical and no direct claim / method-run write")
    func promotionCannotBypassReview() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!all.contains("makeCanonical"))
        #expect(!all.contains("INSERT INTO claims"))
        #expect(!all.contains("INSERT INTO method_runs"))
    }

    @Test("The scenario operation vocabulary is the fixed closed set the schema enforces")
    func closedOpVocabulary() {
        #expect(Set(WorkbenchScenarioOpKind.allCases.map(\.rawValue)) ==
                ["valueOverride", "proposedCorrection", "classification", "annotation", "derivedExperimentalValue", "rowInclusion", "rowExclusion"])
        #expect(Set(WorkbenchScenarioStatus.allCases.map(\.rawValue)) == ["active", "discarded", "promoted"])
        #expect(Set(WorkbenchScenarioPromotionDestination.allCases.map(\.rawValue)) ==
                ["userCorrection", "workingFinding", "methodRunInput", "claimReview", "workProductInput"])
    }

    @Test("LAB-003 adds exactly one schema bump: latest is >= v94 and the scenario tables are created once")
    func oneSchemaBump() throws {
        #expect(SchemaMigrations.latestVersion >= 94)
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for table in ["workbench_scenarios", "workbench_scenario_operations", "workbench_scenario_reviews", "workbench_scenario_events"] {
            #expect(migrations.components(separatedBy: "CREATE TABLE \(table) (").count == 2, "\(table) not created exactly once")
        }
    }

    @Test("The v94 scenario migration suite is registered in the migration matrix")
    func migrationSuiteRegistered() throws {
        #expect(try read("ci/test-groups/migration-matrix.json").contains("WorkbenchScenarioMigrationTests"))
    }
}
