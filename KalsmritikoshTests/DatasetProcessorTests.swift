//
//  DatasetProcessorTests.swift
//  KalsmritikoshTests
//
//  LAB-004 — safe processors preserve evidence lineage: derived cells carry the union of
//  their inputs' source blocks and are marked deterministically derived.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-004 DatasetProcessor")
struct DatasetProcessorTests {

    private let b1 = UUID(), b2 = UUID(), b3 = UUID()

    private func cell(_ v: String, _ b: UUID) -> DatasetCell {
        DatasetCell(value: v, sourceBlockIDs: [b], status: .sourceAsserted)
    }
    private func ds() -> EvidenceDataset {
        EvidenceDataset(name: "payments",
            columns: [DatasetColumn(name: "amount", shape: .money), DatasetColumn(name: "payee", shape: .text)],
            rows: [
                DatasetRow(cells: [cell("₹3,800", b1), cell("Rajesh", b1)]),
                DatasetRow(cells: [cell("₹1,200", b2), cell("Rajesh", b2)]),
                DatasetRow(cells: [cell("₹500", b3), cell("Meera", b3)]),
            ])
    }

    @Test("sum aggregates and carries the union of contributing evidence blocks")
    func sumLineage() {
        let total = DatasetProcessor.sum(ds(), columnIndex: 0)
        #expect(total.value == "5500")
        #expect(Set(total.sourceBlockIDs) == Set([b1, b2, b3]))
        #expect(total.status == .deterministicallyDerived)
        #expect(total.isProvenanced)
    }

    @Test("sum over no numeric cells is missing, not a fabricated zero")
    func sumEmptyIsMissing() {
        let empty = EvidenceDataset(name: "e", columns: [DatasetColumn(name: "x", shape: .text)],
                                    rows: [DatasetRow(cells: [cell("hello", b1)])])
        #expect(DatasetProcessor.sum(empty, columnIndex: 0).value == nil)
    }

    @Test("countByGroup groups and carries per-group lineage")
    func groupLineage() {
        let groups = DatasetProcessor.countByGroup(ds(), keyColumn: 1)
        let rajesh = groups.first { $0.key == "Rajesh" }
        #expect(rajesh?.count == 2)
        #expect(rajesh?.cell.sourceBlockIDs.count == 2)
    }

    @Test("filterRows selects rows and bumps the version")
    func filter() {
        let filtered = DatasetProcessor.filterRows(ds(), columnIndex: 1, contains: "rajesh")
        #expect(filtered.rows.count == 2)
        #expect(filtered.version == ds().version + 1)
    }

    @Test("numeric parses lakh/crore/k scales")
    func numericScales() {
        #expect(DatasetProcessor.numeric("2.70 lac") == 270_000)
        #expect(DatasetProcessor.numeric("₹3,800") == 3800)
    }
}
