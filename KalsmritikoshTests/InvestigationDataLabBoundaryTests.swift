//
//  InvestigationDataLabBoundaryTests.swift
//  KalsmritikoshTests
//
//  INV-01-C3 architecture guards (§28). Prove the Investigator DataLab entry ORCHESTRATES the shared
//  Workbench rather than forking it: no InvestigatorDataLab / dataset repository / transformation or
//  scenario engine / lineage or privacy authority; presets are recipes over the shared Workbench value
//  shapes; case scope reuses CaseRetrievalScopeResolver; SensitiveScope reuses the shared repository; and
//  preparation is driven by the case's authorized source set — it cannot default to workspace-wide inputs.
//  Source scanning + value checks.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C3 — Investigator DataLab architecture guards")
struct InvestigationDataLabBoundaryTests {

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
    private let serviceRel = "Kalsmritikosh/Personas/Investigator/InvestigationDataLabService.swift"
    private let presetRel = "Kalsmritikosh/Personas/Investigator/InvestigationDataLabPreset.swift"
    private func both() throws -> String { codeOnly(try read(serviceRel)) + "\n" + codeOnly(try read(presetRel)) }

    @Test("Both DataLab files are present") func present() {
        #expect((try? read(serviceRel)) != nil && (try? read(presetRel)) != nil)
    }

    @Test("No model names in the DataLab subsystem")
    func noModelNames() throws {
        let lower = try both().lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
    }

    @Test("No forked DataLab engine / dataset repository / transformation / scenario / lineage / privacy authority")
    func noForks() throws {
        let s = try both()
        for banned in ["InvestigatorDataLab", "InvestigatorDatasetRepository", "InvestigatorTransformationEngine",
                       "InvestigatorScenarioEngine", "InvestigatorLineageStore",
                       "actor WorkbenchDatasetRepository", "class WorkbenchDatasetRepository", "struct WorkbenchDataset ",
                       "struct ProtectionLabel", "enum ProtectionLabel", "CREATE TABLE"] {
            #expect(!s.contains(banned), "DataLab forks: \(banned)")
        }
    }

    @Test("Presets compile to the shared Workbench + case scope + shared SensitiveScope")
    func composesShared() throws {
        let service = codeOnly(try read(serviceRel))
        #expect(service.contains("WorkbenchDatasetRepository"))
        #expect(service.contains("CaseRetrievalScopeResolver"))
        #expect(service.contains("SensitiveScopeRepository"))
        #expect(service.contains("effectiveLabel"))               // SensitiveScope intersection, shared
        #expect(service.contains(".permits("))
        #expect(service.contains("bindSource("))                  // exact canonical drill-through
        #expect(codeOnly(try read(presetRel)).contains("FactSchemaRegistry.ValueShape"))   // shared value shapes
    }

    @Test("Preparation is driven by the case's authorized source set — it cannot default to workspace-wide inputs")
    func noWorkspaceFallback() throws {
        let service = codeOnly(try read(serviceRel))
        #expect(service.contains("authorizedSourceVersionIDs"))        // iterates the authorized set
        #expect(!service.contains("datasetIDs(workspaceID"))            // never enumerates all workspace datasets
        #expect(!service.contains("workspace_sources"))                // never reads the whole-workspace source list
        #expect(!service.contains("FROM source_versions"))             // no raw all-sources query
    }

    @Test("The preset catalog exposes exactly the nine INV-01 presets with stable ids and shared shapes")
    func presetCatalogClosed() {
        let ids = Set(InvestigationDataLabPresetCatalog.all.map(\.id))
        #expect(ids.count == 9)
        #expect(ids.contains("inv.datalab.source-inventory"))
        #expect(ids.contains("inv.datalab.contradictions"))
        #expect(ids.contains("inv.datalab.gaps"))
        for p in InvestigationDataLabPresetCatalog.all { #expect(!p.limitations.isEmpty, "\(p.id) states no limitation") }
    }
}
