//
//  WorkbenchTransformBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-002 (Stage C) architecture guards. Prove the safe transformation engine keeps its promises at
//  the SOURCE level: there is NO `eval` / dynamic-code path (no NSExpression, JavaScriptCore, Process,
//  dlopen); the transform layer NEVER mutates canonical evidence (read-only isolation); the transform
//  kind vocabulary is the fixed closed set the schema CHECK enforces; and exactly one schema bump (v93)
//  creates the three lineage tables once. Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — transformation architecture guards")
struct WorkbenchTransformBoundaryTests {

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
        "Kalsmritikosh/Workbench/Transform/WorkbenchValue.swift",
        "Kalsmritikosh/Workbench/Transform/WorkbenchExpression.swift",
        "Kalsmritikosh/Workbench/Transform/WorkbenchExpressionEvaluator.swift",
        "Kalsmritikosh/Workbench/Transform/WorkbenchTransform.swift",
        "Kalsmritikosh/Workbench/Transform/WorkbenchTransformEngine.swift",
        "Kalsmritikosh/Workbench/Persistence/WorkbenchTransformRepository.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The transformation subsystem is present")
    func present() { #expect(files().count == 6) }

    @Test("No model names anywhere in the transformation subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("There is no eval / dynamic-code path (no NSExpression, JavaScriptCore, Process, dlopen)")
    func noEvalPath() {
        let banned = ["NSExpression", "NSPredicate(format", "JavaScriptCore", "JSContext", "dlopen", "dlsym", "Process(", "system("]
        for (name, text) in files() {
            let code = codeOnly(text)
            for token in banned { #expect(!code.contains(token), "\(name) uses a dynamic-code path: \(token)") }
        }
    }

    @Test("The transform layer never mutates canonical evidence (read-only isolation)")
    func canonicalReadOnly() {
        let all = files().map { codeOnly($0.1) }.joined(separator: "\n")
        for table in ["claims", "events", "entities", "evidence_blocks", "source_versions", "contradictions", "gap_nodes", "knowledge_objects"] {
            #expect(!all.contains("INSERT INTO \(table)"), "mutates canonical \(table)")
            #expect(!all.contains("UPDATE \(table) "), "mutates canonical \(table)")
            #expect(!all.contains("DELETE FROM \(table)"), "mutates canonical \(table)")
        }
    }

    @Test("The transform kind vocabulary is the fixed closed set the schema enforces")
    func closedKindVocabulary() {
        #expect(Set(WorkbenchTransformKind.allCases.map(\.rawValue)) ==
                ["calculatedColumn", "runningTotal", "filter", "sort", "deduplicate", "aggregate", "pivot", "join", "rollingCalculation"])
        #expect(WorkbenchTransformKind.supported ==
                [.calculatedColumn, .runningTotal, .filter, .sort, .deduplicate, .aggregate])
        #expect(!WorkbenchTransformKind.pivot.isSupported)
        #expect(WorkbenchTransformKind.calculatedColumn.isSupported)
    }

    @Test("The function allowlist is closed and excludes obvious escape hatches")
    func functionAllowlistClosed() {
        for banned in ["SYSTEM", "EXEC", "EVAL", "SHELL", "IMPORT"] {
            #expect(!WorkbenchFunctionCatalog.allowed.contains(banned), "allowlist admits \(banned)")
        }
        #expect(WorkbenchFunctionCatalog.allowed.contains("IF"))
        #expect(WorkbenchFunctionCatalog.allowed.contains("DATEDIFF"))
    }

    @Test("LAB-002 adds exactly one schema bump: latest is >= v93 and the lineage tables are created once")
    func oneSchemaBump() throws {
        #expect(SchemaMigrations.latestVersion >= 93)
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for table in ["workbench_transformations", "workbench_derivations", "workbench_derivation_inputs"] {
            #expect(migrations.components(separatedBy: "CREATE TABLE \(table)").count == 2, "\(table) not created exactly once")
        }
    }

    @Test("The v93 transformation migration suite is registered in the migration matrix")
    func migrationSuiteRegistered() throws {
        #expect(try read("ci/test-groups/migration-matrix.json").contains("WorkbenchTransformMigrationTests"))
    }
}
