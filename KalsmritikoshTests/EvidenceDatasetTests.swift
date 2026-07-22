//
//  EvidenceDatasetTests.swift
//  KalsmritikoshTests
//
//  LAB-001 — the evidence kernel: every value-bearing cell must drill through to evidence;
//  a derived value with no provenance is rejected by the invariant.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-001 EvidenceDataset")
struct EvidenceDatasetTests {

    private func dataset(_ cell: DatasetCell) -> EvidenceDataset {
        EvidenceDataset(name: "t", columns: [DatasetColumn(name: "amount", shape: .money)],
                        rows: [DatasetRow(cells: [cell])])
    }

    @Test("An evidence-backed cell is provenanced and well-formed")
    func provenanced() {
        let cell = DatasetCell(value: "₹3,800", sourceBlockIDs: [UUID()], status: .sourceAsserted)
        #expect(cell.isProvenanced)
        #expect(dataset(cell).isWellFormed)
    }

    @Test("A value with no evidence and no derivation basis is rejected")
    func unprovenancedRejected() {
        let bad = DatasetCell(value: "₹9,999", sourceBlockIDs: [], status: .sourceAsserted)
        #expect(!bad.isProvenanced)
        #expect(!dataset(bad).isWellFormed)
        #expect(dataset(bad).unprovenancedCells.count == 1)
    }

    @Test("A missing cell is well-formed (explicitly missing, not fabricated)")
    func missingOK() {
        #expect(DatasetCell.missing.isProvenanced)
        #expect(dataset(.missing).isWellFormed)
    }

    @Test("Deterministic derivation / human entry need no source block")
    func derivationBasis() {
        let derived = DatasetCell(value: "8", sourceBlockIDs: [], status: .deterministicallyDerived)
        let human = DatasetCell(value: "x", sourceBlockIDs: [], status: .humanCorrected)
        #expect(derived.isProvenanced)
        #expect(human.isProvenanced)
    }

    @Test("Cell can be built from a GenericFact, carrying its evidence")
    func fromFact() {
        let blk = UUID()
        let fact = GenericFact(subjectLabel: "p", field: "amount", value: "₹3,800",
                               status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blk])
        let cell = DatasetCell.from(fact)
        #expect(cell.value == "₹3,800")
        #expect(cell.sourceBlockIDs == [blk])
        #expect(cell.isProvenanced)
    }
}
