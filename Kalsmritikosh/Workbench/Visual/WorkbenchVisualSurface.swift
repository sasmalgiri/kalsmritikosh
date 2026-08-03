//
//  WorkbenchVisualSurface.swift
//  Kalsmritikosh
//
//  LAB-004 (Stage C) — the ONE shared visual-surface model for the DataLab's reusable native canvases
//  (Table, Timeline, Matrix, Board, Relationship graph, Transaction flow, Chart, Fishbone, Five-Whys
//  chain, Map, Document comparison, Evidence wall, Checklist/form, Notebook). A surface is a
//  presentation-agnostic PROJECTION over existing authorities (datasets, scenarios, evidence) — NOT a
//  second data store. Its load-bearing guarantee is the contract's rule: EVERY visual object supports
//  one-action evidence inspection. That is enforced structurally here — every element carries a
//  non-optional `WorkbenchElementProvenance`, so there is never a dead element whose origin cannot be
//  opened: a source-backed element drills through to the EXACT canonical target + SourceVersion +
//  locator; a scenario value keeps its original source lineage (additive, never replaced); a derived
//  value names its inputs + basis; a user-entered value names its author; and a purely structural label
//  states honestly that it has no source. Nothing here writes to the database.
//

import Foundation

/// The closed set of reusable canvases. The element model below is kind-agnostic, so one surface type
/// serves every canvas; a canvas view (product-shell stage) renders these elements.
public nonisolated enum WorkbenchVisualSurfaceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case table
    case timeline
    case matrix
    case board
    case relationshipGraph
    case transactionFlow
    case chart
    case fishbone
    case fiveWhysChain
    case mapLocation
    case documentComparison
    case evidenceWall
    case checklistForm
    case notebookEditor
}

/// The one-action drill-through behind a visual element: the exact canonical origin. Reuses the LAB-001
/// binding-target vocabulary + the canonical SourceLocator — it forks neither.
public nonisolated struct EvidenceInspectionTarget: Sendable, Equatable {
    public let targetKind: WorkbenchBindingTargetKind
    public let targetID: String
    public let sourceVersionID: UUID?
    public let locator: SourceLocator?

    public nonisolated init(targetKind: WorkbenchBindingTargetKind, targetID: String,
                            sourceVersionID: UUID?, locator: SourceLocator?) {
        self.targetKind = targetKind; self.targetID = targetID
        self.sourceVersionID = sourceVersionID; self.locator = locator
    }

    public nonisolated var targetUUID: UUID? { UUID(uuidString: targetID) }

    /// Build an inspection target from a LAB-001 source binding (the drill-through the dataset already holds).
    public nonisolated static func from(_ binding: WorkbenchSourceBinding) -> EvidenceInspectionTarget {
        EvidenceInspectionTarget(targetKind: binding.targetKind, targetID: binding.targetID,
                                 sourceVersionID: binding.sourceVersionID, locator: binding.locator)
    }
}

/// Where a visual element's value comes from. EVERY element must declare one of these — that is what
/// makes one-action inspection total: each case resolves to either a source target or an explicit,
/// honest basis. There is no "unknown / unexplained" element.
public nonisolated enum WorkbenchElementProvenance: Sendable, Equatable {
    case source(EvidenceInspectionTarget)                       // direct canonical evidence
    case scenario(original: EvidenceInspectionTarget?)          // a scenario overlay; original lineage kept (additive)
    case derived(inputElementIDs: [String], basis: String)      // deterministic calculation over other elements
    case userEntered(actor: String)                             // human-entered, no source
    case none(reason: String)                                   // structural label / heading — honestly no source

    /// The source target to open on inspection, when the element is backed by (or overlays) evidence.
    public nonisolated var inspectionTarget: EvidenceInspectionTarget? {
        switch self {
        case .source(let t): return t
        case .scenario(let original): return original
        case .derived, .userEntered, .none: return nil
        }
    }

    /// A human-readable basis for elements with no direct source target — so inspection is never a dead
    /// end even for derived / entered / structural elements.
    public nonisolated var basisDescription: String {
        switch self {
        case .source: return "source evidence"
        case .scenario(let o): return o == nil ? "scenario what-if value (no original source)" : "scenario overlay of a source value"
        case .derived(let inputs, let basis): return "derived from \(inputs.count) input(s): \(basis)"
        case .userEntered(let actor): return "entered by \(actor)"
        case .none(let reason): return reason
        }
    }
}

/// One element on a canvas (a cell, a node, a bar, a card, a timeline point, …). `row`/`column` are
/// optional spatial hints for grid/matrix canvases; graph/board canvases can ignore them.
public nonisolated struct WorkbenchVisualElement: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: String?
    public let provenance: WorkbenchElementProvenance
    public let row: Int?
    public let column: Int?

    public nonisolated init(id: String, label: String, value: String?,
                            provenance: WorkbenchElementProvenance, row: Int? = nil, column: Int? = nil) {
        self.id = id; self.label = label; self.value = value
        self.provenance = provenance; self.row = row; self.column = column
    }

    /// The one-action inspection target, when this element is source-backed or a scenario overlay.
    public nonisolated var inspectionTarget: EvidenceInspectionTarget? { provenance.inspectionTarget }
}

/// A rendered surface: a kind + a title + its elements. A pure projection — construction guarantees
/// every element already carries provenance (the type system makes an unprovenanced element impossible).
public nonisolated struct WorkbenchVisualSurface: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: WorkbenchVisualSurfaceKind
    public let title: String
    public let elements: [WorkbenchVisualElement]

    public nonisolated init(id: UUID, kind: WorkbenchVisualSurfaceKind, title: String, elements: [WorkbenchVisualElement]) {
        self.id = id; self.kind = kind; self.title = title; self.elements = elements
    }

    public nonisolated func element(id: String) -> WorkbenchVisualElement? { elements.first { $0.id == id } }

    /// One-action evidence inspection: the exact source/locator behind an element, when it has one.
    public nonisolated func inspectionTarget(forElement id: String) -> EvidenceInspectionTarget? {
        element(id: id)?.inspectionTarget
    }

    /// The elements that drill through to canonical evidence (source-backed or scenario overlays of one).
    public nonisolated var sourceBackedElements: [WorkbenchVisualElement] {
        elements.filter { $0.inspectionTarget != nil }
    }

    /// The contract invariant: EVERY element can be inspected in one action — it resolves to either a
    /// source target or an explicit honest basis. True by construction (provenance is non-optional and
    /// total); asserted by tests and the boundary guards.
    public nonisolated var everyElementInspectable: Bool {
        elements.allSatisfy { !$0.provenance.basisDescription.isEmpty }
    }
}
