//
//  SearchView.swift
//  Kalsmritikosh
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
            // The search box lives in the always-visible app header now;
            // this screen just renders results for the current query.
            if hits.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .background(AuroraBackdrop(intensity: 0.6))
        .onAppear { consumePendingQuery() }
        .onChange(of: appState.pendingSearchQuery) { _, _ in consumePendingQuery() }
    }

    /// Pick up a query typed into the always-visible header search box.
    private func consumePendingQuery() {
        guard let pending = appState.pendingSearchQuery,
              !pending.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        query = pending
        appState.pendingSearchQuery = nil
        runSearch()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.brandGradient(0.16))
                    .frame(width: 84, height: 84)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.brandGradient())
            }
            Text("Search your knowledge base")
                .font(Theme.display(24, .bold))
            Text("Full-text search runs instantly across every chunk — no waiting for AI enrichment.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(hits.count) result\(hits.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(hits) { chunk in
                    resultCard(chunk)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func resultCard(_ chunk: Chunk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chunk.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(Theme.brand)
                Text("KO \(chunk.objectID.uuidString.prefix(8)) · chunk #\(chunk.ordinal)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.md)
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
