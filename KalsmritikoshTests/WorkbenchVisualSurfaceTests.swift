//
//  WorkbenchVisualSurfaceTests.swift
//  KalsmritikoshTests
//
//  LAB-004 — the shared visual-surface model + the universal one-action evidence-inspection contract.
//  Proves the closed canvas vocabulary, that every provenance case resolves to either a source target
//  or an explicit honest basis (so no element is ever a dead end), and that a surface resolves the
//  exact inspection target behind a source-backed element. Pure — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-004 — visual-surface model")
struct WorkbenchVisualSurfaceTests {

    @Test("The canvas kind vocabulary is the fixed closed set of 14 surfaces")
    func kindVocabulary() {
        #expect(Set(WorkbenchVisualSurfaceKind.allCases.map(\.rawValue)) ==
                ["table", "timeline", "matrix", "board", "relationshipGraph", "transactionFlow", "chart",
                 "fishbone", "fiveWhysChain", "mapLocation", "documentComparison", "evidenceWall", "checklistForm", "notebookEditor"])
    }

    @Test("An inspection target is built from a source binding, preserving kind + version + locator")
    func inspectionTargetFromBinding() {
        let sv = UUID()
        let binding = WorkbenchSourceBinding(id: UUID(), cellID: UUID(), targetKind: .evidenceBlock,
                                             targetID: "blk-1", sourceVersionID: sv, locator: nil, ordinal: 0,
                                             createdAt: Date(timeIntervalSinceReferenceDate: 0))
        let t = EvidenceInspectionTarget.from(binding)
        #expect(t.targetKind == .evidenceBlock)
        #expect(t.targetID == "blk-1")
        #expect(t.sourceVersionID == sv)
    }

    @Test("Provenance resolves an inspection target for source + scenario, and nil for the rest")
    func provenanceTargetResolution() {
        let t = EvidenceInspectionTarget(targetKind: .sourceVersion, targetID: UUID().uuidString, sourceVersionID: UUID(), locator: nil)
        #expect(WorkbenchElementProvenance.source(t).inspectionTarget == t)
        #expect(WorkbenchElementProvenance.scenario(original: t).inspectionTarget == t)
        #expect(WorkbenchElementProvenance.scenario(original: nil).inspectionTarget == nil)
        #expect(WorkbenchElementProvenance.derived(inputElementIDs: ["a"], basis: "sum").inspectionTarget == nil)
        #expect(WorkbenchElementProvenance.userEntered(actor: "u").inspectionTarget == nil)
        #expect(WorkbenchElementProvenance.none(reason: "header").inspectionTarget == nil)
    }

    @Test("Every provenance case carries a non-empty basis so inspection is never a dead end")
    func everyProvenanceHasBasis() {
        let t = EvidenceInspectionTarget(targetKind: .claim, targetID: "c", sourceVersionID: nil, locator: nil)
        let cases: [WorkbenchElementProvenance] = [
            .source(t), .scenario(original: t), .scenario(original: nil),
            .derived(inputElementIDs: ["x", "y"], basis: "average"), .userEntered(actor: "analyst"), .none(reason: "section heading")]
        for c in cases { #expect(!c.basisDescription.isEmpty) }
    }

    @Test("A surface resolves the one-action inspection target behind a source element")
    func surfaceInspection() {
        let t = EvidenceInspectionTarget(targetKind: .evidenceBlock, targetID: "blk", sourceVersionID: UUID(), locator: nil)
        let surface = WorkbenchVisualSurface(id: UUID(), kind: .table, title: "T", elements: [
            WorkbenchVisualElement(id: "e1", label: "amount", value: "100", provenance: .source(t)),
            WorkbenchVisualElement(id: "e2", label: "note", value: "n", provenance: .userEntered(actor: "u"))])
        #expect(surface.inspectionTarget(forElement: "e1") == t)
        #expect(surface.inspectionTarget(forElement: "e2") == nil)
        #expect(surface.element(id: "missing") == nil)
    }

    @Test("everyElementInspectable holds and sourceBackedElements filters to evidence-backed elements")
    func inspectableInvariant() {
        let t = EvidenceInspectionTarget(targetKind: .claim, targetID: "c", sourceVersionID: nil, locator: nil)
        let surface = WorkbenchVisualSurface(id: UUID(), kind: .matrix, title: "M", elements: [
            WorkbenchVisualElement(id: "a", label: "l", value: "1", provenance: .source(t)),
            WorkbenchVisualElement(id: "b", label: "l", value: "2", provenance: .derived(inputElementIDs: ["a"], basis: "x2")),
            WorkbenchVisualElement(id: "h", label: "hdr", value: "hdr", provenance: .none(reason: "header"))])
        #expect(surface.everyElementInspectable)
        #expect(surface.sourceBackedElements.map(\.id) == ["a"])
    }
}
