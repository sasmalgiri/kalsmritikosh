//
//  KnowledgeView.swift
//  Atlas chronica memora
//
//  Split nav over People / Companies / Projects + Killer features.
//

import SwiftUI

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
}
