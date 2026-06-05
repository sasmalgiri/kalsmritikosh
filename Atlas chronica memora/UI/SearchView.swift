//
//  SearchView.swift
//  Atlas chronica memora
//
//  Faceted + FTS5 search over chunks. M4 covers chunk hits;
//  M5 adds entity/event filters.
//

import SwiftUI

public struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var hits: [Chunk] = []
    @State private var searching = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search timelines, entities, summaries…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            .padding()

            if hits.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Type to search across your knowledge base.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(hits) { chunk in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chunk.text)
                            .lineLimit(4)
                        Text("KO \(chunk.objectID.uuidString.prefix(8)) · chunk #\(chunk.ordinal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let chunks = appState.chunks else { return }
        searching = true
        Task {
            let results = (try? await chunks.searchFTS(q, limit: 40)) ?? []
            await MainActor.run {
                self.hits = results
                self.searching = false
            }
        }
    }
}
