//
//  KnowledgeView.swift
//  Kalsmritikosh
//
//  Split nav over People / Companies / Projects + Killer features.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct KnowledgeView: View {
    @State private var selection: KnowledgeTab = .people

    enum KnowledgeTab: String, CaseIterable, Identifiable, Hashable {
        case people, companies, projects, killer
        var id: String { rawValue }
        // P8.6 — no internal "Killer" naming in user-facing UI.
        var label: String {
            switch self {
            case .killer: return "Highlights"
            default:      return rawValue.capitalized
            }
        }
        var icon: String {
            switch self {
            case .people: return "person.2"
            case .companies: return "building.2"
            case .projects: return "shippingbox"
            case .killer: return "sparkles"
            }
        }
    }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {
                Text("Browse the entities extracted from your files — people, companies, projects — with their mentions and export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                ForEach(KnowledgeTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack {
                            Label(tab.label, systemImage: tab.icon)
                            Spacer()
                            if selection == tab {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Knowledge")
            .frame(minWidth: 220)
        } detail: {
            switch selection {
            case .people: KnowledgeListView(kind: .person)
            case .companies: KnowledgeListView(kind: .organization)
            case .projects: KnowledgeListView(kind: .project)
            case .killer: KillerFeaturesView()
            }
        }
        .background(AuroraBackdrop(intensity: 0.5))
    }
}

private struct KnowledgeListView: View {
    @Environment(AppState.self) private var appState
    let kind: Entity.Kind
    @State private var rows: [EntitySummaryRow] = []
    @State private var excluded: [EntitySummaryRow] = []
    @State private var exportingForID: Entity.ID?
    @State private var showExcluded = false
    /// The entity currently being renamed (drives the correction alert).
    @State private var correcting: EntitySummaryRow?
    @State private var correctionText = ""
    /// v52 merge: the loser awaiting a merge-target choice (drives the picker),
    /// plus the merged-away entities and their reveal toggle.
    @State private var merging: EntitySummaryRow?
    @State private var merged: [EntitySummaryRow] = []
    @State private var showMerged = false

    var body: some View {
        VStack {
            if rows.isEmpty && excluded.isEmpty {
                Text("Nothing here yet. Ingest sources to populate this list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(rows) { row in
                            entityRow(row)
                        }
                    }
                    if showExcluded && !excluded.isEmpty {
                        Section("Excluded — hidden from answers, kept for the record") {
                            ForEach(excluded) { row in
                                excludedRow(row)
                            }
                        }
                    }
                    if showMerged && !merged.isEmpty {
                        Section("Merged — folded into another entity, kept for the record") {
                            ForEach(merged) { row in
                                mergedRow(row)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(kind.rawValue.capitalized)
        .toolbar {
            if !excluded.isEmpty {
                ToolbarItem {
                    Toggle(isOn: $showExcluded) {
                        Label("Excluded (\(excluded.count))", systemImage: "eye.slash")
                    }
                    .toggleStyle(.button)
                }
            }
            if !merged.isEmpty {
                ToolbarItem {
                    Toggle(isOn: $showMerged) {
                        Label("Merged (\(merged.count))", systemImage: "arrow.triangle.merge")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .sheet(item: $merging) { loser in
            MergeTargetPicker(
                loser: loser,
                kind: kind,
                candidates: rows.filter { $0.id != loser.id }
            ) { winner in
                Task { await mergeInto(loser, winner: winner) }
            }
        }
        .alert("Correct spelling", isPresented: Binding(
            get: { correcting != nil },
            set: { if !$0 { correcting = nil } }
        )) {
            TextField("Corrected name", text: $correctionText)
            Button("Cancel", role: .cancel) { correcting = nil }
            Button("Save") {
                if let row = correcting { Task { await applyCorrection(row, to: correctionText) } }
            }
        } message: {
            Text("Adds the corrected spelling so future lookups resolve to this entity. The original is kept; the change is recorded in the Audit trail.")
        }
        .task { await refresh() }
    }

    /// One active entity row + its human-in-loop context menu.
    private func entityRow(_ row: EntitySummaryRow) -> some View {
        HStack {
            EntityChip(row.value, kind: kind)
            Spacer()
            ConfidenceBadge(row.confidence)
        }
        .contextMenu {
            Button {
                Task { await exportDossier(for: row) }
            } label: {
                Label("Export dossier…", systemImage: "square.and.arrow.up")
            }
            .disabled(exportingForID != nil)
            Divider()
            Button {
                correctionText = row.value
                correcting = row
            } label: {
                Label("Correct spelling…", systemImage: "pencil")
            }
            Button {
                merging = row
            } label: {
                Label("Merge into…", systemImage: "arrow.triangle.merge")
            }
            .disabled(rows.count < 2)
            Button(role: .destructive) {
                Task { await reject(row) }
            } label: {
                Label("Reject (exclude)", systemImage: "eye.slash")
            }
        }
    }

    /// One merged (loser) entity row, greyed, with a one-tap Unmerge (split).
    private func mergedRow(_ row: EntitySummaryRow) -> some View {
        HStack {
            EntityChip(row.value, kind: kind)
                .opacity(0.5)
            Spacer()
            Button {
                Task { await unmerge(row) }
            } label: {
                Label("Unmerge", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    /// One excluded entity row, greyed, with a one-tap Restore.
    private func excludedRow(_ row: EntitySummaryRow) -> some View {
        HStack {
            EntityChip(row.value, kind: kind)
                .opacity(0.5)
            Spacer()
            Button {
                Task { await restore(row) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func refresh() async {
        guard let entities = appState.entities else { return }
        let active = (try? await entities.list(kind: kind, limit: 500)) ?? []
        let hidden = (try? await entities.listExcluded(kind: kind, limit: 500)) ?? []
        let folded = (try? await entities.listMerged(kind: kind, limit: 500)) ?? []
        await MainActor.run {
            self.rows = active
            self.excluded = hidden
            self.merged = folded
        }
    }

    // MARK: - Human-in-loop actions (reversible, audit-logged)

    /// Soft-exclude an entity: it stops appearing in the browser, answers, and
    /// dossiers, but is NOT deleted (preserve-everything). Recorded in
    /// fact_reviews so it shows in the Audit trail and can be restored.
    private func reject(_ row: EntitySummaryRow) async {
        guard let entities = appState.entities else { return }
        try? await entities.setReviewStatus(row.id, "rejected")
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .entity, subjectID: row.id, action: .reject,
            priorValue: row.value, reviewer: "user",
            reason: "Excluded from the Knowledge browser"
        ))
        await refresh()
    }

    private func restore(_ row: EntitySummaryRow) async {
        guard let entities = appState.entities else { return }
        try? await entities.setReviewStatus(row.id, nil)
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .entity, subjectID: row.id, action: .accept,
            priorValue: row.value, reviewer: "user", reason: "Restored"
        ))
        await refresh()
    }

    /// Non-destructive rename: keep the original canonical value, add the
    /// corrected spelling as an alias so lookups resolve, and record the
    /// correction in the Audit trail.
    private func applyCorrection(_ row: EntitySummaryRow, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        correcting = nil
        guard !trimmed.isEmpty, trimmed != row.value,
              let entities = appState.entities else { return }
        try? await entities.addAlias(entityID: row.id, aliasNormalized: trimmed, source: "user-correction")
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .entity, subjectID: row.id, action: .correct,
            priorValue: row.value, newValue: trimmed, reviewer: "user",
            reason: "Corrected spelling"
        ))
        await refresh()
    }

    /// Soft-merge `loser` into `winner`: the loser folds under the winner
    /// (mentions combine, old spelling resolves via alias), reversibly. Recorded
    /// in fact_reviews (.merge) for the Audit trail.
    private func mergeInto(_ loser: EntitySummaryRow, winner: EntitySummaryRow) async {
        merging = nil
        guard loser.id != winner.id, let entities = appState.entities else { return }
        do {
            try await entities.merge(loserID: loser.id, winnerID: winner.id)
            _ = try? await appState.factReviews?.record(FactReview(
                subjectKind: .entity, subjectID: loser.id, action: .merge,
                priorValue: loser.value, newValue: winner.value, reviewer: "user",
                reason: "Merged \"\(loser.value)\" into \"\(winner.value)\""
            ))
        } catch {
            // Rejected merges (cycle / cross-kind) are a no-op; nothing to undo.
            print("Merge skipped: \(error)")
        }
        await refresh()
    }

    /// Reverse a merge — the loser reappears as its own entity. Recorded (.split).
    private func unmerge(_ row: EntitySummaryRow) async {
        guard let entities = appState.entities else { return }
        try? await entities.unmerge(loserID: row.id)
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .entity, subjectID: row.id, action: .split,
            priorValue: row.value, reviewer: "user", reason: "Unmerged"
        ))
        await refresh()
    }

    /// Build the markdown dossier and run a save panel so the user
    /// can drop it wherever. We don't auto-save — the user owns
    /// where private knowledge gets written.
    private func exportDossier(for row: EntitySummaryRow) async {
        guard let entities = appState.entities,
              let events = appState.events,
              let objects = appState.objects else { return }
        exportingForID = row.id
        defer { exportingForID = nil }
        let markdown: String?
        do {
            markdown = try await EntityDossier.build(
                forEntityID: row.id,
                entities: entities,
                events: events,
                objects: objects
            )
        } catch {
            markdown = nil
        }
        guard let body = markdown, !body.isEmpty else { return }
        await MainActor.run { saveDossier(body, suggestedName: row.value) }
    }

    @MainActor
    private func saveDossier(_ body: String, suggestedName: String) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        let safe = suggestedName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(safe.isEmpty ? "dossier" : safe).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Failure to write is rare (user-picked URL is sandboxed) —
            // surface in the log; we don't have a toast surface yet.
            print("Dossier export failed: \(error)")
        }
        #endif
    }
}

/// Sheet that picks the WINNER a loser entity should merge into. Shows the
/// same-kind canonicals, searchable; picking one folds the loser into it.
private struct MergeTargetPicker: View {
    let loser: EntitySummaryRow
    let kind: Entity.Kind
    let candidates: [EntitySummaryRow]
    let onPick: (EntitySummaryRow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [EntitySummaryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.value.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \u{201C}\(loser.value)\u{201D} into…")
                .font(.headline)
            Text("Pick the entity these are the same as. \u{201C}\(loser.value)\u{201D} will fold into it — mentions combine and the old spelling still resolves. Reversible; recorded in the Audit trail.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search \(kind.rawValue)s…", text: $query)
                .textFieldStyle(.roundedBorder)
            List(filtered) { row in
                Button {
                    onPick(row)
                    dismiss()
                } label: {
                    HStack {
                        EntityChip(row.value, kind: kind)
                        Spacer()
                        ConfidenceBadge(row.confidence)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 380)
    }
}
