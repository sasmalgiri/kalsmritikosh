//
//  EvidenceBarChartView.swift
//  Kalsmritikosh
//
//  LAB-006 — the chart primitive for the notebook/dashboard builder. A deterministic bar
//  chart that reproduces its values EXACTLY from the data it's given (no smoothing, no
//  interpolation), so a chart in a report matches the underlying evidence figures. Pure
//  SwiftUI; the caller supplies (label, value) pairs already derived from the ledger.
//

import SwiftUI

public struct EvidenceBarChartView: View {
    public struct Bar: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let label: String
        public let value: Double
        public nonisolated init(label: String, value: Double) { self.label = label; self.value = value }
    }

    private let title: String
    private let bars: [Bar]
    public init(title: String, bars: [Bar]) { self.title = title; self.bars = bars }

    private var maxValue: Double { max(bars.map(\.value).max() ?? 0, 0.0001) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if bars.isEmpty {
                Text("No data.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(bars) { bar in
                    HStack(spacing: 8) {
                        Text(bar.label).font(.caption).frame(width: 90, alignment: .trailing).lineLimit(1)
                        GeometryReader { geo in
                            let w = geo.size.width * CGFloat(bar.value / maxValue)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10))
                                RoundedRectangle(cornerRadius: 4).fill(Theme.brand).frame(width: max(2, w))
                            }
                        }
                        .frame(height: 16)
                        // Exact value label — the chart never rounds away the real figure.
                        Text(Self.format(bar.value)).font(.caption2.monospacedDigit())
                            .frame(width: 64, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
    }

    /// Render integers without a decimal, otherwise up to 2 dp — never lossy for display.
    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
