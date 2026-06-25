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
        var label: String { rawValue.capitalized }
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
    }
}

private struct KnowledgeListView: View {
    @Environment(AppState.self) private var appState
    let kind: Entity.Kind
    @State private var rows: [EntitySummaryRow] = []
    @State private var exportingForID: Entity.ID?

    var body: some View {
        VStack {
            if rows.isEmpty {
                Text("Nothing here yet. Ingest sources to populate this list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
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
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(kind.rawValue.capitalized)
        .task { await refresh() }
    }

    private func refresh() async {
        guard let entities = appState.entities else { return }
        let results = (try? await entities.list(kind: kind, limit: 500)) ?? []
        await MainActor.run { self.rows = results }
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
