//
//  LocalMeasurementsPanel.swift
//  Kalsmritikosh
//
//  Unified path QA-20 (owner 2026-11-22) — not tested yet. Settings ▸ Diagnostics: run the measurement
//  tools (RetrievalGoldEval, RetrievalEval, ANNBenchmark, ErrorAnalysisClassifier) over the current ledger,
//  on this Mac, and show counts and scores only — never document content. Nothing is sent or saved.
//

import SwiftUI
import os

struct LocalMeasurementsPanel: View {
    @Environment(AppState.self) private var appState
    @State private var lines: [String: String] = [:]
    @State private var running: String?

    private let tools: [(id: String, title: String)] = [
        ("gold", "Retrieval recall on the gold questions"),
        ("eval", "Keyword-layer recall and precision"),
        ("ann", "Vector index speed and recall (synthetic)"),
        ("errors", "Error kinds on the labelled sample")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measurements on this Mac").font(.headline)
            Text("Scores and counts only, over the current ledger; no document text is shown, sent or saved.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tools, id: \.id) { t in
                HStack(alignment: .firstTextBaseline) {
                    Button(running == t.id ? "Running…" : t.title) { Task { await run(t.id) } }
                        .disabled(running != nil)
                        .controlSize(.small)
                    if let line = lines[t.id] {
                        Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func run(_ id: String) async {
        running = id
        defer { running = nil }
        switch id {
        case "gold":   lines[id] = await appState.measureRetrievalGold()
        case "eval":   lines[id] = await appState.measureRetrievalEval()
        case "ann":    lines[id] = await appState.measureANN()
        default:       lines[id] = await appState.measureErrorAnalysis()
        }
    }
}
