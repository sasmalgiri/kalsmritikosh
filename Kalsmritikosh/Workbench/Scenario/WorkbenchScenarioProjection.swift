//
//  WorkbenchScenarioProjection.swift
//  Kalsmritikosh
//
//  LAB-003 (Stage C) — the pure, deterministic REPLAY of a scenario's applied operation log over its
//  base dataset. It never touches the database, the canonical evidence, the source cells or the LAB-002
//  derivations: it takes the base WorkbenchDatasetRecord + the applied operations and produces the
//  scenario's current overlay view (cell overrides, classifications, annotations, excluded rows), a
//  comparison against the source, and — crucially — a scenario-projected WorkbenchDatasetRecord that can
//  be fed to the ONE existing LAB-002 transform engine so a "transformation over the scenario" reuses
//  the same evaluator rather than forking a second one. Scenario lineage is ADDITIVE: the projected
//  record keeps each cell's original identity so drill-through to the source is preserved.
//

import Foundation

/// One value-level difference between the source and the scenario at a cell.
public nonisolated struct WorkbenchScenarioDiffEntry: Sendable, Equatable {
    public let rowID: UUID
    public let fieldID: UUID
    public let originalValue: String?
    public let scenarioValue: String?
    public let kind: WorkbenchScenarioOpKind
    public let reason: String?

    public nonisolated init(rowID: UUID, fieldID: UUID, originalValue: String?, scenarioValue: String?,
                            kind: WorkbenchScenarioOpKind, reason: String?) {
        self.rowID = rowID; self.fieldID = fieldID; self.originalValue = originalValue
        self.scenarioValue = scenarioValue; self.kind = kind; self.reason = reason
    }
}

/// The materialised, deterministic overlay of a scenario at its current pointer.
public nonisolated struct WorkbenchScenarioProjection: Sendable {

    /// One cell override recorded by replay (the last write wins).
    public nonisolated struct CellOverride: Sendable, Equatable {
        public let value: String?
        public let kind: WorkbenchScenarioOpKind
        public let reason: String?
    }

    public let base: WorkbenchDatasetRecord
    public let cellOverrides: [String: CellOverride]     // key "row|field"
    public let classifications: [String: String]         // key target id (row or "row|field")
    public let annotations: [String: [String]]           // key target id
    public let excludedRows: Set<UUID>

    private nonisolated static func key(_ row: UUID, _ field: UUID) -> String { "\(row.uuidString)|\(field.uuidString)" }

    /// Replay the applied operations (already filtered to live ≤ pointer, in sequence order) over the base.
    public nonisolated static func build(base: WorkbenchDatasetRecord,
                                         appliedOps: [WorkbenchScenarioOperation]) -> WorkbenchScenarioProjection {
        var overrides: [String: CellOverride] = [:]
        var classifications: [String: String] = [:]
        var annotations: [String: [String]] = [:]
        var excluded: Set<UUID> = []
        for op in appliedOps {
            switch op.kind {
            case .valueOverride, .proposedCorrection, .derivedExperimentalValue:
                if let field = op.fieldID {
                    overrides[key(op.rowID, field)] = CellOverride(value: op.afterValue, kind: op.kind, reason: op.reason)
                }
            case .classification:
                classifications[targetID(op)] = op.afterValue
            case .annotation:
                annotations[targetID(op), default: []].append(op.afterValue ?? "")
            case .rowExclusion:
                excluded.insert(op.rowID)
            case .rowInclusion:
                excluded.remove(op.rowID)
            }
        }
        return WorkbenchScenarioProjection(base: base, cellOverrides: overrides,
                                           classifications: classifications, annotations: annotations, excludedRows: excluded)
    }

    private nonisolated static func targetID(_ op: WorkbenchScenarioOperation) -> String {
        if let f = op.fieldID { return key(op.rowID, f) }
        return op.rowID.uuidString
    }

    /// The base (source) value at a cell.
    public nonisolated func baseValue(rowID: UUID, fieldID: UUID) -> String? {
        base.cells.first { $0.rowID == rowID && $0.fieldID == fieldID }?.value
    }

    /// The scenario value at a cell: the override if present, else the source value.
    public nonisolated func projectedValue(rowID: UUID, fieldID: UUID) -> String? {
        if let o = cellOverrides[Self.key(rowID, fieldID)] { return o.value }
        return baseValue(rowID: rowID, fieldID: fieldID)
    }

    /// A scenario-projected WorkbenchDatasetRecord for the LAB-002 engine: excluded rows dropped, cell
    /// values overlaid; each surviving cell keeps its ORIGINAL identity so lineage/drill-through holds.
    public nonisolated func projectedRecord() -> WorkbenchDatasetRecord {
        let rows = base.rows.filter { !excludedRows.contains($0.id) }
        let liveRowIDs = Set(rows.map(\.id))
        var cells: [WorkbenchCell] = []
        // Base cells (with overrides applied) for surviving rows.
        for c in base.cells where liveRowIDs.contains(c.rowID) {
            let v = projectedValue(rowID: c.rowID, fieldID: c.fieldID)
            cells.append(WorkbenchCell(id: c.id, datasetID: c.datasetID, rowID: c.rowID, fieldID: c.fieldID,
                                       kind: c.kind, value: v, status: c.status, createdAt: c.createdAt))
        }
        // Overrides at (row,field) with no base cell → synthesized deterministic scenario cells.
        let existing = Set(base.cells.map { Self.key($0.rowID, $0.fieldID) })
        for (k, o) in cellOverrides where !existing.contains(k) {
            let parts = k.split(separator: "|")
            guard parts.count == 2, let row = UUID(uuidString: String(parts[0])), let field = UUID(uuidString: String(parts[1])),
                  liveRowIDs.contains(row) else { continue }
            cells.append(WorkbenchCell(id: UUID(), datasetID: base.dataset.id, rowID: row, fieldID: field,
                                       kind: .deterministicCalculation, value: o.value, status: .deterministicallyDerived, createdAt: base.dataset.createdAt))
        }
        return WorkbenchDatasetRecord(dataset: base.dataset, fields: base.fields, rows: rows,
                                      cells: cells, bindings: base.bindings, savedViews: [], events: [])
    }

    /// Every value-level difference between source and scenario (excluding classifications/annotations,
    /// which do not change the underlying data value). Deterministic ordering by (row ordinal, field ordinal).
    public nonisolated func diff() -> [WorkbenchScenarioDiffEntry] {
        let rowOrdinal = Dictionary(uniqueKeysWithValues: base.rows.map { ($0.id, $0.ordinal) })
        let fieldOrdinal = Dictionary(uniqueKeysWithValues: base.fields.map { ($0.id, $0.ordinal) })
        var entries: [WorkbenchScenarioDiffEntry] = []
        for (k, o) in cellOverrides {
            let parts = k.split(separator: "|")
            guard parts.count == 2, let row = UUID(uuidString: String(parts[0])), let field = UUID(uuidString: String(parts[1])) else { continue }
            let original = baseValue(rowID: row, fieldID: field)
            if original != o.value {
                entries.append(WorkbenchScenarioDiffEntry(rowID: row, fieldID: field, originalValue: original,
                                                          scenarioValue: o.value, kind: o.kind, reason: o.reason))
            }
        }
        return entries.sorted {
            let ra = rowOrdinal[$0.rowID] ?? 0, rb = rowOrdinal[$1.rowID] ?? 0
            if ra != rb { return ra < rb }
            return (fieldOrdinal[$0.fieldID] ?? 0) < (fieldOrdinal[$1.fieldID] ?? 0)
        }
    }

    /// The original canonical bindings for a cell — the drill-through the scenario NEVER replaces.
    public nonisolated func originalBindings(rowID: UUID, fieldID: UUID) -> [WorkbenchSourceBinding] {
        guard let cell = base.cells.first(where: { $0.rowID == rowID && $0.fieldID == fieldID }) else { return [] }
        return base.bindings(forCell: cell.id)
    }
}

/// The result of a deterministic staleness check for a scenario (computed by the repository against the
/// live dataset). A stale scenario is NEVER silently rewritten — it is preserved as created, with its
/// reasons surfaced for an explicit, provenance-preserving rebase decision.
public nonisolated struct WorkbenchScenarioStaleness: Sendable, Equatable {
    public let scenarioID: UUID
    public let baseDatasetRevision: Int
    public let currentDatasetRevision: Int
    public let baseRevisionChanged: Bool
    public let supersededSourceVersionCount: Int
    public let reasons: [String]

    public nonisolated init(scenarioID: UUID, baseDatasetRevision: Int, currentDatasetRevision: Int,
                            baseRevisionChanged: Bool, supersededSourceVersionCount: Int, reasons: [String]) {
        self.scenarioID = scenarioID; self.baseDatasetRevision = baseDatasetRevision
        self.currentDatasetRevision = currentDatasetRevision; self.baseRevisionChanged = baseRevisionChanged
        self.supersededSourceVersionCount = supersededSourceVersionCount; self.reasons = reasons
    }

    public nonisolated var isStale: Bool { baseRevisionChanged || supersededSourceVersionCount > 0 }
}
