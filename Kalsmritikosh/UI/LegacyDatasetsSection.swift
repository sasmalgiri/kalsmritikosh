//
//  LegacyDatasetsSection.swift
//  Kalsmritikosh
//
//  Unified path IN-21 + MAP-14 (owner 2026-11-22) — not tested yet. Data Lab's entry to the earlier
//  data-set format: DatasetRepository lists and loads them (read-only), TransformationGraph applies
//  undoable filter / sum / count-by-group steps for viewing, TableWorkbenchView shows the grid with its
//  quality inspector, and "Convert" hands the data set to the canonical Workbench (convertLegacy) —
//  the canonical data set becomes the authority; the earlier record is not changed.
//

import SwiftUI
import os

struct LegacyDatasetsSection: View {
    @Environment(AppState.self) private var appState
    let workspaceID: UUID?
    let actor: String
    let reload: () async -> Void
    @State private var items: [(id: UUID, name: String)] = []
    @State private var opened: EvidenceDataset?
    @State private var notice: String?

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Data sets in the earlier format").font(.headline)
                    Text("View them, or convert one into a Data Lab data set (its cells keep their links to the evidence).")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(items, id: \.id) { item in
                        HStack {
                            Text(item.name).font(.callout)
                            Spacer()
                            Button("View") { Task { await view(item.id) } }.controlSize(.small)
                            Button("Convert") { Task { await convert(item.id) } }.controlSize(.small)
                                .disabled(workspaceID == nil)
                                .help("Make a Data Lab data set from this one in the chosen workspace.")
                        }
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task { await load() }
        .sheet(item: $opened) { ds in
            LegacyDatasetViewer(base: ds, repo: repo) { opened = nil }
        }
    }

    private var repo: DatasetRepository? { appState.database.map { DatasetRepository(database: $0) } }

    private func load() async {
        guard let repo else { return }
        do { items = try await repo.list() } catch {
            KalsmritikoshLog.ui.error("Earlier data sets not listed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func view(_ id: UUID) async {
        guard let repo else { return }
        do { opened = try await repo.load(id: id) } catch {
            KalsmritikoshLog.ui.error("Earlier data set not read: \(error.localizedDescription, privacy: .public)")
            notice = "That data set could not be read: \(error.localizedDescription)"
        }
    }

    private func convert(_ id: UUID) async {
        guard let repo, let ws = workspaceID, let canonical = appState.workbenchDatasets else { return }
        do {
            guard let legacy = try await repo.load(id: id) else { notice = "That data set is no longer on file."; return }
            let rec = try await canonical.convertLegacy(legacy, workspaceID: ws, actor: actor, at: Date())
            notice = "Converted into “\(rec.dataset.title)”."
            await reload()
        } catch {
            KalsmritikoshLog.ui.error("Earlier data set not converted: \(error.localizedDescription, privacy: .public)")
            notice = "Not converted: \(error.localizedDescription)"
        }
    }
}

/// The earlier-format data set in the table workbench, with undoable view steps.
private struct LegacyDatasetViewer: View {
    let base: EvidenceDataset
    /// Unified path IN-21 (owner 2026-11-22, round 2) — not tested yet. Where the applied steps are saved (v203).
    let repo: DatasetRepository?
    let close: () -> Void
    @State private var loadedSteps = false
    @State private var graph = TransformationGraph()
    @State private var column = 0
    @State private var needle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Column", selection: $column) {
                    ForEach(Array(base.columns.enumerated()), id: \.offset) { i, c in Text(c.name).tag(i) }
                }
                .frame(maxWidth: 220)
                TextField("contains…", text: $needle).frame(maxWidth: 160)
                Button("Filter") { graph.push(.filterContains(columnIndex: column, needle: needle)) }
                    .disabled(needle.isEmpty || base.columns.isEmpty)
                Button("Sum") { graph.push(.sumColumn(columnIndex: column, resultName: "Sum")) }.disabled(base.columns.isEmpty)
                Button("Count by") { graph.push(.countByGroup(keyColumn: column)) }.disabled(base.columns.isEmpty)
                Button("Undo") { graph.undo() }.disabled(!graph.canUndo)
                Button("Redo") { graph.redo() }.disabled(!graph.canRedo)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(10)
            if !graph.appliedSteps.isEmpty {
                Text("Steps: " + graph.appliedSteps.map(\.label).joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            Divider()
            TableWorkbenchView(dataset: graph.apply(to: base))
        }
        .frame(minWidth: 760, minHeight: 520)
        // Unified path IN-21 (owner 2026-11-22, round 2) — not tested yet. Steps saved as they change, restored on open.
        .task {
            guard let repo else { loadedSteps = true; return }
            do {
                let saved = try await repo.savedSteps(datasetID: base.id)
                if !saved.isEmpty { graph = TransformationGraph(steps: saved) }
            } catch {
                KalsmritikoshLog.ui.error("Data set steps not read: \(error.localizedDescription, privacy: .public)")
            }
            loadedSteps = true
        }
        .onChange(of: graph) { _, g in
            guard loadedSteps, let repo else { return }
            let steps = Array(g.appliedSteps)
            let id = base.id
            Task {
                do { try await repo.saveSteps(datasetID: id, steps: steps) } catch {
                    KalsmritikoshLog.ui.error("Data set steps not saved: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
