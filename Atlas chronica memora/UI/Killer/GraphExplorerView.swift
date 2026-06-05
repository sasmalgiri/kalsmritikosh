//
//  GraphExplorerView.swift
//  Atlas chronica memora
//
//  Deferred Phase-9 visualization. M5 ships a list-of-edges view —
//  a true force-directed canvas lands post-alpha when the moat is
//  proven via Timeline + Brain rather than the graph view itself.
//

import SwiftUI

public struct GraphExplorerView: View {
    @Environment(AppState.self) private var appState
    @State private var entities: [EntitySummaryRow] = []
    @State private var selectedID: Entity.ID?
    @State private var edges: [Relationship] = []

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            List(entities) { row in
                Button {
                    selectedID = row.id
                    Task { await loadEdges(of: row.id) }
                } label: {
                    HStack {
                        EntityChip(row.value)
                        Spacer()
                        if selectedID == row.id {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minWidth: 240, maxWidth: 320)
            Divider()
            VStack {
                if edges.isEmpty {
                    Text("Select an entity to see its relationships.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(edges) { edge in
                        HStack {
                            EntityChip(edge.fromEntityID.uuidString.prefix(8).description)
                            Image(systemName: "arrow.right")
                            Text(edge.kind.rawValue).font(.caption.monospaced())
                            Image(systemName: "arrow.right")
                            EntityChip(edge.toEntityID.uuidString.prefix(8).description)
                            Spacer()
                            ConfidenceBadge(edge.confidence)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task { await loadEntities() }
    }

    private func loadEntities() async {
        guard let entitiesRepo = appState.entities else { return }
        let people = (try? await entitiesRepo.list(kind: .person, limit: 100)) ?? []
        let orgs = (try? await entitiesRepo.list(kind: .organization, limit: 100)) ?? []
        await MainActor.run { self.entities = people + orgs }
    }

    private func loadEdges(of id: Entity.ID) async {
        guard let graph = appState.graph else { return }
        let results = (try? await graph.neighbors(of: id, limit: 50)) ?? []
        await MainActor.run { self.edges = results }
    }
}
