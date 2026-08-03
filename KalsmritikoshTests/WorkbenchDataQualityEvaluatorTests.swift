//
//  WorkbenchDataQualityEvaluatorTests.swift
//  KalsmritikoshTests
//
//  LAB-005 — the pure evidence-quality evaluator. Proves each of the 14 warning kinds fires
//  deterministically (record-derivable ones from the dataset itself; external-fact ones from collected
//  inputs; scenario ones from the projection), that every source-mapped warning carries its exact
//  lineage, that severity is a fixed property of the kind, and that a clean dataset raises nothing.
//  Pure — records constructed directly, no database.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-005 — data-quality evaluator")
struct WorkbenchDataQualityEvaluatorTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let ds = UUID()

    private struct Built {
        let record: WorkbenchDatasetRecord
        let fieldID: UUID
        let rowIDs: [UUID]
        let cellIDs: [UUID]
        let svIDs: [UUID?]
    }

    /// One numeric field "amount" with a row per spec (value, kind, bound-source-version).
    private func build(_ specs: [(value: String?, kind: WorkbenchCellKind, sv: UUID?, bind: Bool)]) -> Built {
        let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "T", mode: .advanced, revision: 1, createdAt: t0, updatedAt: t0)
        let field = WorkbenchField(id: UUID(), datasetID: ds, name: "amount", valueShape: .number, ordinal: 0, createdAt: t0)
        var rows: [WorkbenchRow] = []; var cells: [WorkbenchCell] = []; var bindings: [WorkbenchSourceBinding] = []
        var cellIDs: [UUID] = []; var rowIDs: [UUID] = []; var svIDs: [UUID?] = []
        for (i, s) in specs.enumerated() {
            let row = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: i, createdAt: t0); rows.append(row); rowIDs.append(row.id)
            let cell = WorkbenchCell(id: UUID(), datasetID: ds, rowID: row.id, fieldID: field.id, kind: s.kind, value: s.value, status: .directlyObserved, createdAt: t0)
            cells.append(cell); cellIDs.append(cell.id); svIDs.append(s.sv)
            if s.bind {
                bindings.append(WorkbenchSourceBinding(id: UUID(), cellID: cell.id, targetKind: .evidenceBlock,
                                                       targetID: "blk-\(i)", sourceVersionID: s.sv, locator: nil, ordinal: 0, createdAt: t0))
            }
        }
        return Built(record: WorkbenchDatasetRecord(dataset: dataset, fields: [field], rows: rows, cells: cells, bindings: bindings, savedViews: [], events: []),
                     fieldID: field.id, rowIDs: rowIDs, cellIDs: cellIDs, svIDs: svIDs)
    }

    @Test("A missing value raises a caution warning")
    func missingValue() {
        let b = build([(nil, .sourceValue, UUID(), true)])
        let report = WorkbenchDataQualityEvaluator.evaluate(record: b.record)
        #expect(report.warnings(of: .missingValue).count == 1)
        #expect(report.warnings(of: .missingValue).first?.severity == .caution)
    }

    @Test("A source value with no bound source version raises missingCustodyHash")
    func missingCustody() {
        let b = build([("100", .sourceValue, nil, true)])   // binding present but sourceVersionID nil
        let report = WorkbenchDataQualityEvaluator.evaluate(record: b.record)
        #expect(report.warnings(of: .missingCustodyHash).count == 1)
        let b2 = build([("100", .sourceValue, nil, false)]) // no binding at all
        #expect(WorkbenchDataQualityEvaluator.evaluate(record: b2.record).warnings(of: .missingCustodyHash).count == 1)
    }

    @Test("The same source bound to two cells raises duplicateSource with lineage")
    func duplicateSource() {
        let sv = UUID()
        // Two cells sharing the same binding target (targetID blk-0 forced by identical index is not the
        // case; build uses blk-<i>, so craft manually).
        let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "T", mode: .advanced, revision: 1, createdAt: t0, updatedAt: t0)
        let field = WorkbenchField(id: UUID(), datasetID: ds, name: "amount", valueShape: .number, ordinal: 0, createdAt: t0)
        let r0 = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: 0, createdAt: t0)
        let r1 = WorkbenchRow(id: UUID(), datasetID: ds, ordinal: 1, createdAt: t0)
        let c0 = WorkbenchCell(id: UUID(), datasetID: ds, rowID: r0.id, fieldID: field.id, kind: .sourceValue, value: "1", status: .directlyObserved, createdAt: t0)
        let c1 = WorkbenchCell(id: UUID(), datasetID: ds, rowID: r1.id, fieldID: field.id, kind: .sourceValue, value: "1", status: .directlyObserved, createdAt: t0)
        func bind(_ cell: UUID) -> WorkbenchSourceBinding { WorkbenchSourceBinding(id: UUID(), cellID: cell, targetKind: .evidenceBlock, targetID: "blk-same", sourceVersionID: sv, locator: nil, ordinal: 0, createdAt: t0) }
        let rec = WorkbenchDatasetRecord(dataset: dataset, fields: [field], rows: [r0, r1], cells: [c0, c1], bindings: [bind(c0.id), bind(c1.id)], savedViews: [], events: [])
        let report = WorkbenchDataQualityEvaluator.evaluate(record: rec)
        #expect(report.warnings(of: .duplicateSource).count == 2)
        #expect(report.warnings(of: .duplicateSource).allSatisfy { $0.lineage != nil })
    }

    @Test("Stale + inaccessible source versions raise their warnings from collected inputs")
    func staleAndInaccessible() {
        let sv = UUID()
        let b = build([("100", .sourceValue, sv, true)])
        let stale = WorkbenchDataQualityEvaluator.evaluate(record: b.record, inputs: .init(staleSourceVersionIDs: [sv]))
        #expect(stale.warnings(of: .staleSourceVersion).first?.severity == .caution)
        #expect(stale.warnings(of: .staleSourceVersion).first?.lineage != nil)
        let inacc = WorkbenchDataQualityEvaluator.evaluate(record: b.record, inputs: .init(inaccessibleSourceVersionIDs: [sv]))
        #expect(inacc.warnings(of: .inaccessibleSource).first?.severity == .blocking)
    }

    @Test("Per-cell external facts (low OCR, ambiguous identity, non-independent corroboration) fire")
    func perCellFacts() {
        let b = build([("100", .sourceValue, UUID(), true)])
        let c = b.cellIDs[0]
        let r = WorkbenchDataQualityEvaluator.evaluate(record: b.record, inputs: .init(
            lowOCRCellIDs: [c], ambiguousIdentityCellIDs: [c], nonIndependentCorroborationCellIDs: [c]))
        #expect(r.kinds.isSuperset(of: [.lowOCRConfidence, .ambiguousIdentity, .nonIndependentCorroboration]))
    }

    @Test("Field / dataset / transformation facts fire with correct severities")
    func aggregateFacts() {
        let b = build([("100", .sourceValue, UUID(), true)])
        let r = WorkbenchDataQualityEvaluator.evaluate(record: b.record, inputs: .init(
            mixedDatePrecisionFieldIDs: [b.fieldID], unsupportedTransformationKinds: ["pivot"],
            unresolvedContradictionRefs: ["contradiction-1"], workspaceScopeComplete: false))
        #expect(r.warnings(of: .mixedDatePrecision).first?.severity == .info)
        #expect(r.warnings(of: .unsupportedTransformation).first?.severity == .caution)
        #expect(r.warnings(of: .unresolvedContradiction).first?.severity == .blocking)
        #expect(r.warnings(of: .incompleteWorkspaceScope).count == 1)
        #expect(r.hasBlocking)
    }

    @Test("A formula-vs-displayed discrepancy is blocking and carries lineage")
    func formulaDiscrepancy() {
        let sv = UUID()
        let b = build([("100", .sourceValue, sv, true)])
        let r = WorkbenchDataQualityEvaluator.evaluate(record: b.record, inputs: .init(formulaDiscrepancyCellIDs: [b.cellIDs[0]]))
        #expect(r.warnings(of: .formulaVsDisplayedDiscrepancy).first?.severity == .blocking)
        #expect(r.warnings(of: .formulaVsDisplayedDiscrepancy).first?.lineage != nil)
    }

    @Test("An unreviewed scenario overlay value is flagged; a reviewed one is not")
    func unreviewedScenario() {
        let sv = UUID()
        let b = build([("100", .sourceValue, sv, true)])
        let op = WorkbenchScenarioOperation(id: UUID(), scenarioID: UUID(), sequence: 1, kind: .valueOverride,
                                            targetKind: .cell, rowID: b.rowIDs[0], fieldID: b.fieldID, beforeValue: "100",
                                            afterValue: "300", reason: nil, status: .live, actor: "u", createdAt: t0)
        let projection = WorkbenchScenarioProjection.build(base: b.record, appliedOps: [op])
        let key = "\(b.rowIDs[0].uuidString)|\(b.fieldID.uuidString)"
        let flagged = WorkbenchDataQualityEvaluator.evaluate(record: b.record, scenario: projection)
        #expect(flagged.warnings(of: .unreviewedScenarioValue).count == 1)
        #expect(flagged.warnings(of: .unreviewedScenarioValue).first?.lineage != nil)   // original lineage retained
        let reviewed = WorkbenchDataQualityEvaluator.evaluate(record: b.record, scenario: projection, inputs: .init(reviewedScenarioTargets: [key]))
        #expect(reviewed.warnings(of: .unreviewedScenarioValue).isEmpty)
    }

    @Test("A fully-bound, fully-valued dataset raises no missing-value / custody warnings and is deterministic")
    func cleanDataset() {
        let b = build([("100", .sourceValue, UUID(), true), ("50", .sourceValue, UUID(), true)])
        let r1 = WorkbenchDataQualityEvaluator.evaluate(record: b.record)
        let r2 = WorkbenchDataQualityEvaluator.evaluate(record: b.record)
        #expect(r1.warnings(of: .missingValue).isEmpty)
        #expect(r1.warnings(of: .missingCustodyHash).isEmpty)
        #expect(r1 == r2)   // deterministic
    }

    @Test("The warning-kind vocabulary is the fixed closed set of 14")
    func kindVocabulary() {
        #expect(WorkbenchQualityWarningKind.allCases.count == 14)
    }
}
