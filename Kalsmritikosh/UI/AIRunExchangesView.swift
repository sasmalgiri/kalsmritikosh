//
//  AIRunExchangesView.swift
//  Kalsmritikosh
//
//  ALCOA ALC-14 (owner 2026-11-24) — Settings ▸ Online ▸ What was sent ▸ AI replies and tool steps: for each agent run,
//  every reply body the AI sent back and each step's tool calls and the app's results, in order, with the SHA-256 kept
//  for each (and whether the body still matches it). Small expressions on purpose (CI type-check budget).
//

import SwiftUI
import os

struct AIRunExchangesView: View {
    @Environment(AppState.self) private var appState
    @State private var exchanges: [CaseAIRecordRepository.RunExchange] = []
    @State private var problem: String?
    @State private var open: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI replies and tool steps (kept per run)").font(.headline)
            Text("What each AI run received back and what this Mac's tools answered — kept in the encrypted ledger, erased with the case or the person.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if exchanges.isEmpty, problem == nil { Text("No AI run has been kept yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(exchanges.prefix(200)) { e in row(e) }
        }
        .task { await load() }
    }

    private func row(_ e: CaseAIRecordRepository.RunExchange) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(header(e)) { open = open == e.id ? nil : e.id }.buttonStyle(.plain).font(.caption.weight(.semibold))
            if open == e.id {
                Text(e.body.prefix(20_000)).font(.caption2.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ e: CaseAIRecordRepository.RunExchange) -> String {
        let kind = e.kind == "reply" ? "AI reply" : (e.kind == "toolCalls" ? "tool calls" : "tool results")
        let integrity = e.intact ? "SHA-256 \(e.bodySHA256.prefix(12))… matches" : "SHA-256 does NOT match"
        return "Run \(e.runID.uuidString.prefix(8)) · step \(e.step) · \(kind)\(e.modelServed.map { " · \($0)" } ?? "") · \(integrity)"
    }

    private func load() async {
        guard let db = appState.database else { return }
        do { exchanges = try await CaseAIRecordRepository(database: db).exchanges() } catch {
            KalsmritikoshLog.ui.error("AI run exchanges not read: \(error.localizedDescription, privacy: .private)")
            problem = "The kept AI replies could not be read (\(error.localizedDescription))."
        }
    }
}
