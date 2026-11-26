//
//  ComparisonService.swift
//  Kalsmritikosh
//
//  G3 Workflow C — the seam that turns per-source field data into a
//  comparison result. It wires the pure ComparisonMatrix / ComparisonBrief
//  to INJECTED reads (a closure), so the deterministic core never touches
//  the database directly. The caller supplies a resolver that, for a given
//  field and source, returns what that source says (a value / explicitly
//  none / silent); the service assembles the matrix and renders the brief.
//

import Foundation

public struct ComparisonService: Sendable {
    /// What a single source says about a single field. Injected so the pure
    /// comparison core stays testable and DB-free.
    public let fieldValue: @Sendable (_ field: String, _ sourceID: String) async -> SourceValue.Presence

    public init(fieldValue: @escaping @Sendable (_ field: String, _ sourceID: String) async -> SourceValue.Presence) {
        self.fieldValue = fieldValue
    }

    /// Compare `fields` across `sources`, preserving source order. Returns the
    /// classified cells and the rendered brief (labelled by source).
    public func compare(
        fields: [String],
        sources: [(id: String, label: String)]
    ) async -> (cells: [ComparisonCell], brief: ComparisonBrief) {
        let sourceIDs = sources.map(\.id)
        // Speed PERF-29 (owner 2026-11-23) — not tested yet. The cells are read concurrently (bounded by the Mac's
        // worker budget, work stealing over the grid) and placed back in field and source order.
        let cellCount = fields.count * sources.count
        let read = fieldValue
        let fieldList = fields, sourceList = sourceIDs
        let presences = await WorkStealingQueue.map(count: cellCount, workers: min(8, WorkStealingQueue.cpuWidth())) { k in
            await read(fieldList[k / sourceList.count], sourceList[k % sourceList.count])
        }
        var values: [String: [SourceValue]] = [:]
        for (fi, field) in fields.enumerated() {
            values[field] = sources.indices.map { si in
                SourceValue(sourceID: sources[si].id, presence: presences[fi * sources.count + si] ?? .silent)
            }
        }
        let cells = ComparisonMatrix.build(fields: fields, sourceIDs: sourceIDs, values: values)
        let labels = Dictionary(sources.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        let brief = ComparisonBrief.make(cells: cells, sourceLabels: labels)
        return (cells, brief)
    }
}
