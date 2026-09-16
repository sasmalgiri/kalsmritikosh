//
//  ComparisonBriefView.swift
//  Kalsmritikosh
//
//  G3 Workflow C — the comparison brief surface. Presentational: it renders
//  a deterministic ComparisonBrief (built from the matrix) into the reader's
//  view — Agreements, Disagreements, Different-units (marked "not a
//  conflict"), Missing/unresolved, and the source register. Every line comes
//  from the matrix, so the view can never assert a comparison the evidence
//  does not support. Takes a ComparisonBrief so it stays testable/previewable
//  and decoupled from data gathering.
//

import SwiftUI

public struct ComparisonBriefView: View {
    let brief: ComparisonBrief
    /// Optional export action (PDF/Markdown) wired by the host; hidden when nil.
    let onExport: (() -> Void)?

    public init(brief: ComparisonBrief, onExport: (() -> Void)? = nil) {
        self.brief = brief
        self.onExport = onExport
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !brief.agreements.isEmpty {
                    section("Agreements", systemImage: "checkmark.seal.fill", color: .green, lines: brief.agreements)
                }
                if !brief.disagreements.isEmpty {
                    section("Disagreements", systemImage: "exclamationmark.triangle.fill", color: .orange, lines: brief.disagreements)
                }
                if !brief.differentUnits.isEmpty {
                    section("Different units — not conflicts", systemImage: "arrow.left.arrow.right", color: .blue, lines: brief.differentUnits)
                }
                if !brief.unresolved.isEmpty {
                    section("Missing / unresolved", systemImage: "questionmark.circle", color: .secondary, lines: brief.unresolved)
                }
                sourceRegister
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.split.2x1")
                .foregroundStyle(.tint).font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Comparison brief").font(.title3.weight(.semibold))
                Text("Agreements, disagreements and what no source settles — each line from the sources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onExport {
                Button {
                    onExport()
                } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func section(_ title: String, systemImage: String, color: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline).foregroundStyle(color)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(color)
                    Text(line).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    @ViewBuilder private var sourceRegister: some View {
        if !brief.sourceRegister.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sources compared").font(.subheadline.weight(.semibold))
                Text(brief.sourceRegister.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
