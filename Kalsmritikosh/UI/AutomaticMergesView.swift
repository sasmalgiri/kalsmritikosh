//
//  AutomaticMergesView.swift
//  Kalsmritikosh
//
//  Unified path IN-18 (owner 2026-11-22, round 2) — not tested yet. The undo screen for name merges the app
//  made by itself (register refresh after an import, OCR-variant folds) and merges a person made, read from the
//  append-only reconciliation audit. Each can be undone; the undo is recorded as its own event.
//

import SwiftUI
import os

struct AutomaticMergesView: View {
    @Environment(AppState.self) private var appState
    @State private var merges: [EntityReconciliationAuditRepository.OpenMerge] = []
    @State private var names: [UUID: String] = [:]
    @State private var status: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text("Names the app joined as one — after an import (cleaned names that collided) or as a likely scanning slip of a better-attested name. Undo any of them; nothing is deleted either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if merges.isEmpty, !loading {
                Text("No merges to undo.").foregroundStyle(.secondary)
            }
            ForEach(merges) { m in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(m.losers.map { names[$0] ?? "an earlier name" }.joined(separator: ", ")) → \(names[m.winner] ?? "a name")")
                        Text("\(Self.originLabel(m.origin)) · \(m.at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Undo") {
                        Task {
                            status = await appState.undoEntityMerge(m)
                            await load()
                        }
                    }
                    .help("Split these names apart again. The undo is recorded in the audit.")
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .listStyle(.inset)
        .navigationTitle("Automatic merges")
        .task { await load() }
    }

    static func originLabel(_ origin: String) -> String {
        if origin.hasPrefix("ocrVariant") { return "Likely scanning slip" }
        switch origin {
        case "registerRefresh": return "Cleaned name matched another"
        case "review": return "Merged by you"
        default: return "Merge"
        }
    }

    private func load() async {
        defer { loading = false }
        guard let db = appState.database, let entities = appState.entities else { return }
        do {
            merges = try await EntityReconciliationAuditRepository(database: db).openMerges()
            let ids = Array(Set(merges.flatMap { [$0.winner] + $0.losers }))
            var out: [UUID: String] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                for e in try await entities.findByIDs(chunk, limit: chunk.count) { out[e.id] = e.value }
            }
            names = out
        } catch {
            KalsmritikoshLog.ui.error("Automatic merges not loaded: \(error.localizedDescription, privacy: .public)")
            status = "Could not load the merges: \(error.localizedDescription)"
        }
    }
}
