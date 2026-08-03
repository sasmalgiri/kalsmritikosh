//
//  WorkbenchSurfaceProjector.swift
//  Kalsmritikosh
//
//  LAB-004 (Stage C) — deterministic projectors that turn existing Workbench authorities into the shared
//  visual-surface model. They are pure functions over already-loaded records: no database access, no
//  network, no mutation of canonical evidence or dataset cells. Each projected element carries its
//  provenance so one-action evidence inspection is total — a source cell drills through to its exact
//  canonical binding; a scenario overlay keeps the original source lineage (additive); a deterministic
//  calculation / model proposal names its basis; a user entry names its author; a structural header
//  states honestly that it has no source. The generic builder REFUSES an element with no provenance, so
//  a canvas can never surface a value whose origin cannot be opened.
//

import Foundation

public nonisolated enum WorkbenchVisualSurfaceError: Error, Sendable, Equatable {
    case elementMissingProvenance(id: String)
    case blankTitle
}

public nonisolated enum WorkbenchSurfaceProjector {

    // MARK: - Table

    /// Project a dataset record into a Table surface. Column headers are structural (no source); each
    /// cell's provenance is derived from its kind and — for a source value — its canonical binding.
    public nonisolated static func tableSurface(from record: WorkbenchDatasetRecord,
                                                surfaceID: UUID = UUID()) -> WorkbenchVisualSurface {
        var elements: [WorkbenchVisualElement] = []
        let fields = record.fields.sorted { $0.ordinal < $1.ordinal }
        let rows = record.rows.sorted { $0.ordinal < $1.ordinal }

        for field in fields {
            elements.append(WorkbenchVisualElement(id: "header:\(field.id.uuidString)", label: field.name,
                                                   value: field.name, provenance: .none(reason: "column header"),
                                                   row: -1, column: field.ordinal))
        }
        for row in rows {
            for field in fields {
                guard let cell = record.cells.first(where: { $0.rowID == row.id && $0.fieldID == field.id }) else { continue }
                let provenance = cellProvenance(cell, in: record)
                elements.append(WorkbenchVisualElement(id: "cell:\(cell.id.uuidString)", label: field.name,
                                                       value: cell.value, provenance: provenance,
                                                       row: row.ordinal, column: field.ordinal))
            }
        }
        return WorkbenchVisualSurface(id: surfaceID, kind: .table, title: record.dataset.title, elements: elements)
    }

    /// The provenance of a dataset cell for surfacing: a source value drills through to its first
    /// canonical binding (or honestly none if unbound); other kinds name their basis / author.
    private nonisolated static func cellProvenance(_ cell: WorkbenchCell, in record: WorkbenchDatasetRecord) -> WorkbenchElementProvenance {
        switch cell.kind {
        case .sourceValue:
            if let binding = record.bindings(forCell: cell.id).first {
                return .source(EvidenceInspectionTarget.from(binding))
            }
            return .none(reason: "source value with no recorded binding")
        case .deterministicCalculation:
            return .derived(inputElementIDs: [], basis: "deterministic calculation")
        case .modelProposal:
            return .derived(inputElementIDs: [], basis: "model proposal (unreviewed)")
        case .userEntered:
            return .userEntered(actor: "user")
        case .userCorrected:
            return .userEntered(actor: "user (corrected)")
        case .reviewed:
            return .userEntered(actor: "reviewer")
        }
    }

    // MARK: - Scenario comparison (Document comparison canvas)

    /// Project a scenario's differences against its source into a Document-comparison surface. Each
    /// changed cell becomes one element showing "original → scenario"; the ORIGINAL source lineage is
    /// preserved as the inspection target (scenario lineage is additive, never a replacement).
    public nonisolated static func scenarioComparisonSurface(projection: WorkbenchScenarioProjection,
                                                             title: String,
                                                             surfaceID: UUID = UUID()) -> WorkbenchVisualSurface {
        var elements: [WorkbenchVisualElement] = []
        for entry in projection.diff() {
            let original = projection.originalBindings(rowID: entry.rowID, fieldID: entry.fieldID).first
                .map(EvidenceInspectionTarget.from)
            let value = "\(entry.originalValue ?? "∅") → \(entry.scenarioValue ?? "∅")"
            elements.append(WorkbenchVisualElement(id: "diff:\(entry.rowID.uuidString)|\(entry.fieldID.uuidString)",
                                                   label: entry.reason ?? entry.kind.rawValue, value: value,
                                                   provenance: .scenario(original: original)))
        }
        return WorkbenchVisualSurface(id: surfaceID, kind: .documentComparison, title: title, elements: elements)
    }

    // MARK: - Generic builder (mandatory-inspection gate)

    /// A raw element spec whose provenance is OPTIONAL — the builder rejects any element that omits it,
    /// enforcing the one-action-inspection contract for canvases assembled from arbitrary inputs.
    public nonisolated struct RawElement: Sendable {
        public let id: String
        public let label: String
        public let value: String?
        public let provenance: WorkbenchElementProvenance?
        public let row: Int?
        public let column: Int?
        public nonisolated init(id: String, label: String, value: String?,
                                provenance: WorkbenchElementProvenance?, row: Int? = nil, column: Int? = nil) {
            self.id = id; self.label = label; self.value = value
            self.provenance = provenance; self.row = row; self.column = column
        }
    }

    /// Assemble any canvas kind from raw elements. Fails closed: an element with no provenance is
    /// rejected (a surface can never render a value whose origin cannot be inspected).
    public nonisolated static func build(kind: WorkbenchVisualSurfaceKind, title: String,
                                         elements raw: [RawElement], surfaceID: UUID = UUID()) throws -> WorkbenchVisualSurface {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchVisualSurfaceError.blankTitle }
        var built: [WorkbenchVisualElement] = []
        for r in raw {
            guard let provenance = r.provenance else { throw WorkbenchVisualSurfaceError.elementMissingProvenance(id: r.id) }
            built.append(WorkbenchVisualElement(id: r.id, label: r.label, value: r.value, provenance: provenance, row: r.row, column: r.column))
        }
        return WorkbenchVisualSurface(id: surfaceID, kind: kind, title: title, elements: built)
    }
}
