//
//  WorkbenchBoundaryTests.swift
//  KalsmritikoshTests
//
//  LAB-001 (Stage C) architecture guards. Prove the Workbench dataset model is the ONE canonical
//  dataset authority and does not fork truth or privacy: the canonical repository never mutates
//  canonical evidence and never persists via the legacy prototype tables; SensitiveScope is composed
//  from the shared authority, not reimplemented; the legacy EvidenceDataset is clearly superseded;
//  exactly one schema bump (v92) creates the Workbench tables once. Source scanning + value checks —
//  no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-001 — Workbench architecture guards")
struct WorkbenchBoundaryTests {

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
    private let workbenchRels = [
        "Kalsmritikosh/Workbench/Domain/WorkbenchDataset.swift",
        "Kalsmritikosh/Workbench/Persistence/WorkbenchDatasetRepository.swift",
        "Kalsmritikosh/Workbench/Persistence/WorkbenchLegacyCompat.swift",
        "Kalsmritikosh/Workbench/Persistence/WorkbenchSensitivity.swift"]
    private func workbenchFiles() -> [(String, String)] { workbenchRels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The Workbench subsystem is present")
    func present() { #expect(workbenchFiles().count == 4) }

    @Test("No model names anywhere in the Workbench subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in workbenchFiles() {
            let lower = text.lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The canonical repository never mutates canonical evidence (read-only isolation)")
    func canonicalReadOnly() throws {
        let code = codeOnly((try? read("Kalsmritikosh/Workbench/Persistence/WorkbenchDatasetRepository.swift")) ?? "")
            + codeOnly((try? read("Kalsmritikosh/Workbench/Persistence/WorkbenchLegacyCompat.swift")) ?? "")
        for table in ["claims", "events", "entities", "evidence_blocks", "source_versions", "contradictions", "gap_nodes", "knowledge_objects"] {
            #expect(!code.contains("INSERT INTO \(table)"), "mutates canonical \(table)")
            #expect(!code.contains("UPDATE \(table) "), "mutates canonical \(table)")
            #expect(!code.contains("DELETE FROM \(table)"), "mutates canonical \(table)")
        }
    }

    @Test("The Workbench never persists through the legacy prototype tables")
    func noLegacyPersistence() throws {
        let code = workbenchFiles().map { codeOnly($0.1) }.joined(separator: "\n")
        #expect(!code.contains("evidence_datasets"))
        #expect(!code.contains("dataset_rows"))
    }

    @Test("SensitiveScope is composed from the shared authority, not reimplemented")
    func sensitiveScopeShared() throws {
        let s = try read("Kalsmritikosh/Workbench/Persistence/WorkbenchSensitivity.swift")
        let code = codeOnly(s)
        #expect(code.contains("SensitiveScopeRepository"))     // delegates to the shared authority
        #expect(!code.contains("enum ProtectionLabel"))        // no forked label vocabulary
        #expect(!code.contains("enum SensitivityLevel"))
    }

    @Test("The legacy EvidenceDataset prototype is clearly marked superseded")
    func legacySuperseded() throws {
        let legacy = try read("Kalsmritikosh/Core/Models/EvidenceDataset.swift")
        #expect(legacy.contains("SUPERSEDED"))
        #expect(legacy.contains("WorkbenchDatasetRepository"))
    }

    @Test("Cell-kind and binding-target vocabularies are the fixed canonical sets")
    func closedVocabularies() {
        #expect(Set(WorkbenchCellKind.allCases.map(\.rawValue)) ==
                ["sourceValue", "deterministicCalculation", "userEntered", "userCorrected", "modelProposal", "reviewed"])
        #expect(Set(WorkbenchBindingTargetKind.allCases.map(\.rawValue)) ==
                ["evidenceBlock", "claim", "event", "entity", "sourceVersion", "contradiction", "gap", "knowledgeObject"])
        #expect(WorkbenchCellKind.sourceValue.requiresSourceBinding)
        #expect(!WorkbenchCellKind.userEntered.requiresSourceBinding)
    }

    @Test("LAB-001 adds exactly one schema bump: latest is v92 and the Workbench tables are created once")
    func oneSchemaBump() throws {
        #expect(SchemaMigrations.latestVersion >= 92)   // v92 = LAB-001; later units (LAB-002+) bump higher
        let migrations = try read("Kalsmritikosh/Storage/Schema/SchemaMigrations.swift")
        for table in ["workbench_datasets", "workbench_fields", "workbench_rows", "workbench_cells",
                      "workbench_source_bindings", "workbench_saved_views", "workbench_dataset_events"] {
            // Match the exact creation "CREATE TABLE <table> (" so the LAB-002 v93 events-table rebuild
            // (workbench_dataset_events_v93) is not counted as a second creation of workbench_dataset_events.
            #expect(migrations.components(separatedBy: "CREATE TABLE \(table) (").count == 2, "\(table) not created exactly once")
        }
    }

    @Test("The v92 Workbench migration suite is registered in the migration matrix")
    func migrationSuiteRegistered() throws {
        #expect(try read("ci/test-groups/migration-matrix.json").contains("WorkbenchDatasetMigrationTests"))
    }
}
