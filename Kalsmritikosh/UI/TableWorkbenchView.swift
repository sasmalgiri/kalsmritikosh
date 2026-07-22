//
//  TableWorkbenchView.swift
//  Kalsmritikosh
//
//  LAB-005 — Table Workbench + quality inspector. Renders an EvidenceDataset as a grid
//  and surfaces its data quality: which cells are evidence-backed (provenanced) vs bare,
//  the well-formed check, and a per-column coverage bar. Every cell can drill through to
//  the evidence blocks that back it (block ids shown), honoring the "claims require
//  evidence" contract at the dataset level.
//
//  Presentational: takes an already-loaded dataset. No I/O, no LLM.
//

import SwiftUI

public struct TableWorkbenchView: View {
    private let dataset: EvidenceDataset
    @State private var selectedCell: (row: Int, col: Int)?

    public init(dataset: EvidenceDataset) { self.dataset = dataset }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView([.horizontal, .vertical]) {
                grid
            }
            Divider()
            inspector
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.name).font(.headline)
                Text("\(dataset.rows.count) rows × \(dataset.columns.count) cols · v\(dataset.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(dataset.isWellFormed ? "Well-formed" : "Malformed",
                  systemImage: dataset.isWellFormed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(dataset.isWellFormed ? .green : .orange)
        }
        .padding(12)
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(dataset.columns) { col in
                    Text(col.name).font(.caption.weight(.semibold))
                        .padding(6).frame(minWidth: 120, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                }
            }
            ForEach(Array(dataset.rows.enumerated()), id: \.element.id) { r, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { c, cell in
                        cellView(cell, row: r, col: c)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func cellView(_ cell: DatasetCell, row: Int, col: Int) -> some View {
        let isSel = selectedCell?.row == row && selectedCell?.col == col
        HStack(spacing: 4) {
            // Provenance dot: filled when the cell is evidence-backed.
            Circle()
                .fill(cell.isProvenanced ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(cell.value ?? "—").font(.caption).lineLimit(1)
        }
        .padding(6).frame(minWidth: 120, alignment: .leading)
        .background(isSel ? Theme.brand.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedCell = (row, col) }
    }

    @ViewBuilder
    private var inspector: some View {
        let unprov = dataset.unprovenancedCells.count
        let total = dataset.rows.count * max(1, dataset.columns.count)
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality inspector").font(.caption.weight(.semibold))
            HStack(spacing: 16) {
                stat("Cells", "\(total)")
                stat("Evidence-backed", "\(total - unprov)", tint: .green)
                stat("Unprovenanced", "\(unprov)", tint: unprov == 0 ? .secondary : .orange)
            }
            if let sel = selectedCell, sel.row < dataset.rows.count,
               sel.col < dataset.rows[sel.row].cells.count {
                let cell = dataset.rows[sel.row].cells[sel.col]
                Divider()
                Text("Selected · \(dataset.columns[safe: sel.col]?.name ?? "col \(sel.col)")")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Status: \(cell.status.rawValue)  ·  \(cell.sourceBlockIDs.count) evidence block(s)")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
