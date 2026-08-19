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
    /// Chunks the user soft-excluded this session (greyed with a Restore).
    @State private var excludedIDs: Set<Chunk.ID> = []

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
            Button {
                SurfaceOpener.open(.sources)
            } label: { Label("Add your files", systemImage: "folder") }
                .buttonStyle(.borderedProminent)
                .help("Nothing to search yet? Point the app at a folder — search works the moment files are read")
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
        let excluded = excludedIDs.contains(chunk.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(chunk.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .strikethrough(excluded)
                .foregroundStyle(excluded ? .secondary : .primary)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(Theme.brand)
                Text("KO \(chunk.objectID.uuidString.prefix(8)) · chunk #\(chunk.ordinal)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Human-in-loop: exclude this passage from search + answers.
                if excluded {
                    Label("Excluded", systemImage: "eye.slash")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button("Restore") { Task { await setExcluded(chunk, false) } }
                        .font(.caption2).buttonStyle(.borderless).controlSize(.small)
                } else {
                    Button {
                        Task { await setExcluded(chunk, true) }
                    } label: {
                        Label("Reject", systemImage: "eye.slash")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Exclude this passage from search and answers (reversible, recorded in the Audit trail)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(excluded ? 0.6 : 1)
        .cardSurface(cornerRadius: Theme.Radius.md)
    }

    /// Soft-exclude or restore a chunk. Never deletes the passage — flips
    /// review_status and records an append-only FactReview for the Audit trail.
    private func setExcluded(_ chunk: Chunk, _ excluded: Bool) async {
        guard let chunks = appState.chunks else { return }
        try? await chunks.setReviewStatus(chunk.id, excluded ? "rejected" : nil)
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .chunk, subjectID: chunk.id,
            action: excluded ? .reject : .accept,
            priorValue: String(chunk.text.prefix(120)), reviewer: "user",
            reason: excluded ? "Excluded passage from search" : "Restored passage"
        ))
        await MainActor.run {
            if excluded { excludedIDs.insert(chunk.id) } else { excludedIDs.remove(chunk.id) }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let chunks = appState.chunks else { return }
        searching = true
        Task {
            let results = (try? await chunks.searchFTS(q, limit: 40)) ?? []
            let filtered = await appState.screenAuthorizer?.filterChunks(results, boundary: .globalOwner) ?? []
            await MainActor.run {
                self.hits = filtered
                self.searching = false
            }
        }
    }
}
