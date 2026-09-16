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
        var values: [String: [SourceValue]] = [:]
        for field in fields {
            var row: [SourceValue] = []
            for s in sources {
                let presence = await fieldValue(field, s.id)
                row.append(SourceValue(sourceID: s.id, presence: presence))
            }
            values[field] = row
        }
        let cells = ComparisonMatrix.build(fields: fields, sourceIDs: sourceIDs, values: values)
        let labels = Dictionary(sources.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        let brief = ComparisonBrief.make(cells: cells, sourceLabels: labels)
        return (cells, brief)
    }
}
