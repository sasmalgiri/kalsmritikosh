//
//  TransformationGraph.swift
//  Kalsmritikosh
//
//  LAB-003 — a versioned transformation graph over the EvidenceDataset kernel. A dataset is
//  produced by applying an ordered list of vetted transforms (LAB-004) to a base dataset.
//  The graph supports undo / redo / branch so analysis is reproducible and reversible — and
//  because every transform preserves lineage, the final table still drills through to source.
//
//  Pure value type, deterministic: applying the same graph to the same base always yields
//  the same dataset (reproducibility). No arbitrary code — only the DatasetTransform cases.
//

import Foundation

/// A single vetted transform step (maps to a DatasetProcessor op).
public enum DatasetTransform: Codable, Sendable, Hashable {
    case filterContains(columnIndex: Int, needle: String)
    case sumColumn(columnIndex: Int, resultName: String)
    case countByGroup(keyColumn: Int)

    public nonisolated var label: String {
        switch self {
        case .filterContains(let c, let n): return "filter col\(c) ~ \"\(n)\""
        case .sumColumn(let c, _):          return "sum col\(c)"
        case .countByGroup(let c):          return "countByGroup col\(c)"
        }
    }
}

public struct TransformationGraph: Sendable, Hashable {
    public private(set) var steps: [DatasetTransform]
    /// How many steps are currently applied (cursor). Steps beyond it are redoable.
    public private(set) var cursor: Int

    public nonisolated init(steps: [DatasetTransform] = []) {
        self.steps = steps
        self.cursor = steps.count
    }

    public var appliedSteps: ArraySlice<DatasetTransform> { steps.prefix(cursor) }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < steps.count }

    /// Append a step (truncates any redoable tail — a new edit forks the redo history).
    public nonisolated mutating func push(_ t: DatasetTransform) {
        if cursor < steps.count { steps.removeLast(steps.count - cursor) }
        steps.append(t)
        cursor += 1
    }

    public nonisolated mutating func undo() { if canUndo { cursor -= 1 } }
    public nonisolated mutating func redo() { if canRedo { cursor += 1 } }

    /// Branch a new graph from the current cursor (independent analysis line).
    public nonisolated func branch() -> TransformationGraph {
        TransformationGraph(steps: Array(appliedSteps))
    }

    /// Apply the currently-applied steps to a base dataset. Deterministic + lineage-preserving.
    /// Aggregations (sum/countByGroup) reduce to a single-row summary dataset.
    public nonisolated func apply(to base: EvidenceDataset) -> EvidenceDataset {
        var ds = base
        for step in appliedSteps {
            switch step {
            case .filterContains(let col, let needle):
                ds = DatasetProcessor.filterRows(ds, columnIndex: col, contains: needle)
            case .sumColumn(let col, let name):
                let cell = DatasetProcessor.sum(ds, columnIndex: col)
                ds = EvidenceDataset(name: ds.name, version: ds.version + 1,
                                     columns: [DatasetColumn(name: name, shape: .number)],
                                     rows: [DatasetRow(cells: [cell])])
            case .countByGroup(let key):
                let groups = DatasetProcessor.countByGroup(ds, keyColumn: key)
                ds = EvidenceDataset(name: ds.name, version: ds.version + 1,
                    columns: [DatasetColumn(name: "group", shape: .text),
                              DatasetColumn(name: "count", shape: .number)],
                    rows: groups.map { g in
                        DatasetRow(cells: [
                            DatasetCell(value: g.key, sourceBlockIDs: g.cell.sourceBlockIDs, status: .deterministicallyDerived),
                            g.cell
                        ])
                    })
            }
        }
        return ds
    }
}
