//
//  TransformationGraphTests.swift
//  KalsmritikoshTests
//
//  LAB-003 — versioned transform graph: deterministic apply, undo/redo, branch; lineage
//  preserved through the pipeline.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-003 TransformationGraph")
struct TransformationGraphTests {

    private let b1 = UUID(), b2 = UUID(), b3 = UUID()
    private func cell(_ v: String, _ b: UUID) -> DatasetCell {
        DatasetCell(value: v, sourceBlockIDs: [b], status: .sourceAsserted)
    }
    private func base() -> EvidenceDataset {
        EvidenceDataset(name: "pay",
            columns: [DatasetColumn(name: "amount", shape: .money), DatasetColumn(name: "payee", shape: .text)],
            rows: [DatasetRow(cells: [cell("₹3,800", b1), cell("Rajesh", b1)]),
                   DatasetRow(cells: [cell("₹1,200", b2), cell("Rajesh", b2)]),
                   DatasetRow(cells: [cell("₹500", b3), cell("Meera", b3)])])
    }

    @Test("filter then sum yields the group total with preserved lineage")
    func filterThenSum() {
        var g = TransformationGraph()
        g.push(.filterContains(columnIndex: 1, needle: "Rajesh"))
        g.push(.sumColumn(columnIndex: 0, resultName: "total"))
        let r = g.apply(to: base())
        #expect(r.rows.first?.cells.first?.value == "5000")
        #expect(r.rows.first?.cells.first?.sourceBlockIDs.count == 2)
    }

    @Test("undo/redo move the cursor without losing steps")
    func undoRedo() {
        var g = TransformationGraph()
        g.push(.filterContains(columnIndex: 1, needle: "Rajesh"))
        g.push(.sumColumn(columnIndex: 0, resultName: "t"))
        g.undo()
        #expect(g.appliedSteps.count == 1)
        #expect(g.canRedo)
        #expect(g.apply(to: base()).rows.count == 2)   // filter-only
        g.redo()
        #expect(g.appliedSteps.count == 2)
    }

    @Test("a new push after undo forks the redo tail")
    func forkOnPush() {
        var g = TransformationGraph()
        g.push(.filterContains(columnIndex: 1, needle: "Rajesh"))
        g.push(.sumColumn(columnIndex: 0, resultName: "t"))
        g.undo()
        g.push(.countByGroup(keyColumn: 1))
        #expect(!g.canRedo)                 // old sum step dropped
        #expect(g.steps.count == 2)
    }

    @Test("branch forks an independent line at the cursor")
    func branch() {
        var g = TransformationGraph()
        g.push(.filterContains(columnIndex: 1, needle: "Rajesh"))
        let child = g.branch()
        #expect(child.steps.count == 1)
    }

    @Test("apply is deterministic for the same graph + base")
    func deterministic() {
        var g = TransformationGraph()
        g.push(.countByGroup(keyColumn: 1))
        #expect(g.apply(to: base()) == g.apply(to: base()))
    }
}
