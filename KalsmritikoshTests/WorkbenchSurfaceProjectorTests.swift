//
//  WorkbenchSurfaceProjectorTests.swift
//  KalsmritikoshTests
//
//  LAB-004 — the deterministic surface projectors. Proves a Table surface carries the exact source
//  binding behind a source cell (and honest basis for derived/entered/unbound cells), a scenario
//  Document-comparison surface preserves the ORIGINAL source lineage (additive), the generic builder
//  refuses an element with no provenance (mandatory inspection), and any canvas kind is buildable.
//  Pure — records are constructed directly, no database.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-004 — surface projectors")
struct WorkbenchSurfaceProjectorTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let ds = UUID()

    /// A one-row dataset with fields (amount: source+bound, calc: deterministic, note: userEntered,
    /// orphan: source but unbound).
    private func record() -> (WorkbenchDatasetRecord, [String: UUID], UUID) {
        let sv = UUID()
        let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "Ledger", mode: .advanced, revision: 1, createdAt: t0, updatedAt: t0)
        func field(_ n: String, _ i: Int) -> WorkbenchField { WorkbenchField(id: UUID(), datasetID: ds, name: n, valueShape: .text, ordinal: i, createdAt: t0) }
        let fAmount = field("amount", 0), fCalc = field("calc", 1), fNote = field("note", 2), fOrphan = field("orphan", 3)
        let row = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: 0, createdAt: t0)
        func cell(_ f: WorkbenchField, _ kind: WorkbenchCellKind, _ v: String) -> WorkbenchCell {
            WorkbenchCell(id: UUID(), datasetID: ds, rowID: row.id, fieldID: f.id, kind: kind, value: v, status: .directlyObserved, createdAt: t0)
        }
        let cAmount = cell(fAmount, .sourceValue, "100")
        let cCalc = cell(fCalc, .deterministicCalculation, "200")
        let cNote = cell(fNote, .userEntered, "hello")
        let cOrphan = cell(fOrphan, .sourceValue, "x")
        let binding = WorkbenchSourceBinding(id: UUID(), cellID: cAmount.id, targetKind: .evidenceBlock,
                                             targetID: "blk-1", sourceVersionID: sv, locator: nil, ordinal: 0, createdAt: t0)
        let rec = WorkbenchDatasetRecord(dataset: dataset, fields: [fAmount, fCalc, fNote, fOrphan], rows: [row],
                                         cells: [cAmount, cCalc, cNote, cOrphan], bindings: [binding], savedViews: [], events: [])
        return (rec, ["amount": cAmount.id, "calc": cCalc.id, "note": cNote.id, "orphan": cOrphan.id], sv)
    }

    @Test("A Table surface carries the exact source binding behind a source cell")
    func tableSourceProvenance() {
        let (rec, cells, sv) = record()
        let surface = WorkbenchSurfaceProjector.tableSurface(from: rec)
        #expect(surface.kind == .table)
        let amount = surface.element(id: "cell:\(cells["amount"]!.uuidString)")!
        guard case .source(let t) = amount.provenance else { Issue.record("expected source"); return }
        #expect(t.targetKind == .evidenceBlock && t.targetID == "blk-1" && t.sourceVersionID == sv)
    }

    @Test("A Table surface maps derived / entered / unbound cells to honest non-source provenance")
    func tableOtherProvenance() {
        let (rec, cells, _) = record()
        let surface = WorkbenchSurfaceProjector.tableSurface(from: rec)
        if case .derived = surface.element(id: "cell:\(cells["calc"]!.uuidString)")!.provenance {} else { Issue.record("calc not derived") }
        if case .userEntered = surface.element(id: "cell:\(cells["note"]!.uuidString)")!.provenance {} else { Issue.record("note not userEntered") }
        if case .none = surface.element(id: "cell:\(cells["orphan"]!.uuidString)")!.provenance {} else { Issue.record("orphan not none") }
        // Column headers are present as structural (no source).
        #expect(surface.elements.contains { $0.id.hasPrefix("header:") })
        #expect(surface.everyElementInspectable)
    }

    @Test("A scenario Document-comparison surface preserves the original source lineage (additive)")
    func scenarioComparison() {
        let (rec, cells, sv) = record()
        _ = sv
        let row = rec.rows[0].id
        let amountField = rec.fields.first { $0.name == "amount" }!.id
        let op = WorkbenchScenarioOperation(id: UUID(), scenarioID: UUID(), sequence: 1, kind: .valueOverride,
                                            targetKind: .cell, rowID: row, fieldID: amountField, beforeValue: "100",
                                            afterValue: "300", reason: "what if", status: .live, actor: "u", createdAt: t0)
        let projection = WorkbenchScenarioProjection.build(base: rec, appliedOps: [op])
        let surface = WorkbenchSurfaceProjector.scenarioComparisonSurface(projection: projection, title: "Compare")
        #expect(surface.kind == .documentComparison)
        #expect(surface.elements.count == 1)
        let e = surface.elements[0]
        #expect(e.value == "100 → 300")
        guard case .scenario(let original) = e.provenance else { Issue.record("expected scenario"); return }
        #expect(original?.targetKind == .evidenceBlock)   // original source lineage retained, not replaced
        _ = cells
    }

    @Test("The generic builder refuses an element with no provenance (mandatory inspection)")
    func builderRejectsMissingProvenance() {
        #expect(throws: WorkbenchVisualSurfaceError.self) {
            _ = try WorkbenchSurfaceProjector.build(kind: .board, title: "B", elements: [
                WorkbenchSurfaceProjector.RawElement(id: "x", label: "l", value: "v", provenance: nil)])
        }
        #expect(throws: WorkbenchVisualSurfaceError.self) {
            _ = try WorkbenchSurfaceProjector.build(kind: .board, title: "  ", elements: [])
        }
    }

    @Test("The generic builder assembles any canvas kind from provenanced elements")
    func builderAllKinds() throws {
        let t = EvidenceInspectionTarget(targetKind: .event, targetID: "ev", sourceVersionID: nil, locator: nil)
        for kind in WorkbenchVisualSurfaceKind.allCases {
            let s = try WorkbenchSurfaceProjector.build(kind: kind, title: "\(kind.rawValue)", elements: [
                WorkbenchSurfaceProjector.RawElement(id: "e", label: "l", value: "v", provenance: .source(t))])
            #expect(s.kind == kind)
            #expect(s.everyElementInspectable)
            #expect(s.inspectionTarget(forElement: "e") == t)
        }
    }
}
