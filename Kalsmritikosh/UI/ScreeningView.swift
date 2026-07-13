//
//  ScreeningView.swift
//  Kalsmritikosh
//
//  Persona features (F9). A transparent single-user screening log with
//  PRISMA-compatible flow counts (§14). Counts recalculate deterministically
//  from the records; every exclusion must carry a reason; decisions are
//  reversible; no AI makes the final inclusion decision. Presented as a sheet
//  from a research-review workspace.
//

import SwiftUI

public struct ScreeningView: View {
    @Environment(AppState.self) private var appState
    let workspace: Workspace
    let onClose: () -> Void

    @State private var records: [ScreeningRecord] = []
    @State private var counts = PRISMACounts()
    @State private var newTitle = ""
    @State private var newAuthors = ""
    @State private var newYear = ""
    @State private var errorText: String?

    public init(workspace: Workspace, onClose: @escaping () -> Void) {
        self.workspace = workspace
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            countsStrip
            Divider()
            addRow
            if let e = errorText {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            recordsList
        }
        .padding(18)
        .frame(width: 720, height: 560)
        .task { await reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Screening log").font(.title2.weight(.semibold))
                Text(workspace.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose).keyboardShortcut(.cancelAction)
        }
    }

    private var countsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                countPill("Identified", counts.identified)
                countPill("Duplicates", counts.duplicatesRemoved)
                countPill("Screened", counts.screened)
                countPill("Excl. (screen)", counts.excludedAtScreening)
                countPill("Full-text", counts.fullTextReviewed)
                countPill("Excl. (full-text)", counts.fullTextExcluded)
                countPill("Included", counts.included, highlight: true)
                countPill("Awaiting", counts.awaitingInformation)
            }
        }
    }

    private func countPill(_ label: String, _ value: Int, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((highlight ? Color.green : Color.primary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Authors", text: $newAuthors).textFieldStyle(.roundedBorder).frame(width: 140)
            TextField("Year", text: $newYear).textFieldStyle(.roundedBorder).frame(width: 60)
            Button("Add") { Task { await add() } }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(records) { r in recordRow(r) }
            }
        }
    }

    private func recordRow(_ r: ScreeningRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let a = r.authors { Text("\(a)\(r.year.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(role: .destructive) { Task { await delete(r) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { r.stage }, set: { v in Task { await update(r) { $0.stage = v } } })) {
                    ForEach(ScreeningStage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 180)
                Picker("", selection: Binding(get: { r.decision }, set: { v in Task { await update(r) { $0.decision = v } } })) {
                    ForEach(ScreeningDecision.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 120)
                if r.decision == .exclude {
                    TextField("Exclusion reason (required)", text: Binding(
                        get: { r.exclusionReason ?? "" },
                        set: { v in Task { await update(r) { $0.exclusionReason = v } } }
                    )).textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
    }

    // MARK: - I/O

    private func reload() async {
        guard let repo = appState.screening else { return }
        let rs = (try? await repo.records(inWorkspace: workspace.id)) ?? []
        let c = PRISMACounts.from(rs)
        await MainActor.run { self.records = rs; self.counts = c }
    }

    private func add() async {
        guard let repo = appState.screening else { return }
        let rec = ScreeningRecord(
            workspaceID: workspace.id,
            title: newTitle.trimmingCharacters(in: .whitespaces),
            authors: newAuthors.isEmpty ? nil : newAuthors,
            year: Int(newYear.trimmingCharacters(in: .whitespaces))
        )
        try? await repo.upsert(rec)
        await MainActor.run { newTitle = ""; newAuthors = ""; newYear = ""; errorText = nil }
        await reload()
    }

    private func update(_ r: ScreeningRecord, _ mutate: (inout ScreeningRecord) -> Void) async {
        guard let repo = appState.screening else { return }
        var copy = r
        mutate(&copy)
        copy.updatedAt = Date()
        do {
            try await repo.upsert(copy)
            await MainActor.run { errorText = nil }
        } catch {
            await MainActor.run { errorText = (error as? ScreeningError)?.errorDescription ?? "\(error)" }
        }
        await reload()
    }

    private func delete(_ r: ScreeningRecord) async {
        guard let repo = appState.screening else { return }
        try? await repo.delete(r.id)
        await reload()
    }
}
