//
//  WorkbenchModeTests.swift
//  KalsmritikoshTests
//
//  LAB-006 (Stage C closure) — Simple and Advanced are two presentations of the ONE Workbench. Proves
//  the mode policy exposes guided controls in Simple and the full detail set in Advanced (a strict
//  superset), that presentation slices the SAME quality report / visual surface without recomputing,
//  that a Simple guided preset compiles to a REAL LAB-002 transform spec, and — the load-bearing proof
//  — that a Simple preset and an equivalent Advanced transform run through the SAME engine and yield an
//  IDENTICAL result (one truth, two presentations). Pure — records constructed directly, no database.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-006 — Simple & Advanced modes")
struct WorkbenchModeTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let ds = UUID()

    // MARK: - Policy

    @Test("Simple exposes guided outcome-first controls but no formula editor / raw editing / multi-view")
    func simpleCapabilities() {
        let c = WorkbenchModePolicy.capabilities(for: .simple)
        #expect(c.terminology == .minimal)
        #expect(c.lineageOnDemand && c.safeDefaults)
        #expect(c.exposes(.recommendedAnalyses) && c.exposes(.naturalLanguageDataLab) && c.exposes(.lineageInspection))
        #expect(!c.exposes(.formulaEditor))
        #expect(!c.exposes(.rawFieldRowCellEditing))
        #expect(!c.exposes(.multiViewLayouts))
    }

    @Test("Advanced exposes the full detailed control set with full terminology and always-on lineage")
    func advancedCapabilities() {
        let c = WorkbenchModePolicy.capabilities(for: .advanced)
        #expect(c.terminology == .full)
        #expect(!c.lineageOnDemand)
        for control in [WorkbenchModeControl.formulaEditor, .rawFieldRowCellEditing, .transformationRecipes,
                        .scenarioBuilder, .qualityIssueList, .multiViewLayouts, .methodAttachment, .savedLayouts] {
            #expect(c.exposes(control), "advanced missing \(control)")
        }
    }

    @Test("Advanced controls are a strict superset of Simple's (one engine, more surface)")
    func advancedSuperset() {
        #expect(WorkbenchModePolicy.advancedIsSupersetOfSimple)
        #expect(WorkbenchModePolicy.capabilities(for: .advanced).controls.count > WorkbenchModePolicy.capabilities(for: .simple).controls.count)
    }

    // MARK: - Presentation (same artifact, two views)

    @Test("Presentation slices the SAME quality report: Simple hides info, Advanced shows all")
    func presentationSlicesSameReport() {
        let warnings = [
            WorkbenchQualityWarning(kind: .duplicateSource, severity: .info, targetID: "a", message: "m", lineage: nil),
            WorkbenchQualityWarning(kind: .missingValue, severity: .caution, targetID: "b", message: "m", lineage: nil),
            WorkbenchQualityWarning(kind: .unresolvedContradiction, severity: .blocking, targetID: "c", message: "m", lineage: nil)]
        let report = WorkbenchDataQualityReport(datasetID: ds, scenarioID: nil, warnings: warnings)
        let simple = WorkbenchModePresentation.warningsToSurface(mode: .simple, report: report)
        let advanced = WorkbenchModePresentation.warningsToSurface(mode: .advanced, report: report)
        #expect(simple.count == 2)                       // info hidden
        #expect(advanced.count == 3)                     // all shown
        #expect(!simple.contains { $0.severity == .info })
        #expect(WorkbenchModePresentation.showsLineageInline(mode: .advanced))
        #expect(!WorkbenchModePresentation.showsLineageInline(mode: .simple))
    }

    // MARK: - Presets compile to REAL LAB-002 specs

    @Test("The Simple preset catalog covers every preset kind and each compiles to a real transform spec")
    func presetsCompile() throws {
        #expect(Set(WorkbenchModePresetCatalog.simplePresets.map(\.kind)) == Set(WorkbenchAnalysisPresetKind.allCases))
        let p = WorkbenchPresetParameters(groupByField: "cat", valueField: "amount", threshold: "100",
                                          sortField: "amount", keyField: "cat", newFieldName: "cum")
        #expect(try WorkbenchModePresetCatalog.compile(.totalByCategory, parameters: p) == .aggregate(function: .sum, field: "amount", groupBy: ["cat"]))
        #expect(try WorkbenchModePresetCatalog.compile(.countByCategory, parameters: p) == .aggregate(function: .count, field: nil, groupBy: ["cat"]))
        #expect(try WorkbenchModePresetCatalog.compile(.averageByCategory, parameters: p) == .aggregate(function: .average, field: "amount", groupBy: ["cat"]))
        #expect(try WorkbenchModePresetCatalog.compile(.sortLowToHigh, parameters: p) == .sort(field: "amount", direction: .ascending))
        #expect(try WorkbenchModePresetCatalog.compile(.sortHighToLow, parameters: p) == .sort(field: "amount", direction: .descending))
        #expect(try WorkbenchModePresetCatalog.compile(.runningTotal, parameters: p) == .runningTotal(newField: "cum", over: "amount"))
        #expect(try WorkbenchModePresetCatalog.compile(.removeDuplicates, parameters: p) == .deduplicate(keyFields: ["cat"]))
        if case .filter(let pred) = try WorkbenchModePresetCatalog.compile(.keepRowsAbove, parameters: p) { #expect(pred == "[amount] > 100") } else { Issue.record("not a filter") }
    }

    @Test("Compiling a preset with a missing required parameter fails closed")
    func presetMissingParameter() {
        #expect(throws: WorkbenchModePresetError.self) {
            _ = try WorkbenchModePresetCatalog.compile(.totalByCategory, parameters: WorkbenchPresetParameters(groupByField: "cat"))
        }
    }

    // MARK: - One engine, two presentations (the Stage-C closure proof)

    private func record() -> WorkbenchDatasetRecord {
        let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "Payments", mode: .simple, revision: 1, createdAt: t0, updatedAt: t0)
        let cat = WorkbenchField(id: UUID(), datasetID: ds, name: "cat", valueShape: .text, ordinal: 0, createdAt: t0)
        let amt = WorkbenchField(id: UUID(), datasetID: ds, name: "amount", valueShape: .number, ordinal: 1, createdAt: t0)
        var rows: [WorkbenchRow] = []; var cells: [WorkbenchCell] = []
        for (i, (c, a)) in [("A", "100"), ("B", "50"), ("A", "25")].enumerated() {
            let row = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: i, createdAt: t0); rows.append(row)
            cells.append(WorkbenchCell(id: UUID(), datasetID: ds, rowID: row.id, fieldID: cat.id, kind: .sourceValue, value: c, status: .directlyObserved, createdAt: t0))
            cells.append(WorkbenchCell(id: UUID(), datasetID: ds, rowID: row.id, fieldID: amt.id, kind: .sourceValue, value: a, status: .directlyObserved, createdAt: t0))
        }
        return WorkbenchDatasetRecord(dataset: dataset, fields: [cat, amt], rows: rows, cells: cells, bindings: [], savedViews: [], events: [])
    }

    @Test("A Simple guided preset and an Advanced transform run through the SAME engine to an IDENTICAL result")
    func oneEngineTwoPresentations() throws {
        let rec = record()
        // Simple: the user picks "Total by category".
        let simpleSpec = try WorkbenchModePresetCatalog.compile(.totalByCategory, parameters: WorkbenchPresetParameters(groupByField: "cat", valueField: "amount"))
        // Advanced: the user authors the equivalent aggregate transform by hand.
        let advancedSpec = WorkbenchTransformSpec.aggregate(function: .sum, field: "amount", groupBy: ["cat"])
        // Same spec type → the ONE engine → identical outcome.
        let simpleOutcome = try WorkbenchTransformEngine.compute(simpleSpec, over: rec)
        let advancedOutcome = try WorkbenchTransformEngine.compute(advancedSpec, over: rec)
        #expect(simpleOutcome == advancedOutcome)
        guard case .aggregate(let agg) = simpleOutcome else { Issue.record("expected aggregate"); return }
        #expect(Dictionary(uniqueKeysWithValues: agg.groups.map { ($0.resultKey ?? "", $0.value.storedString) })["A"] == "125")
    }
}
