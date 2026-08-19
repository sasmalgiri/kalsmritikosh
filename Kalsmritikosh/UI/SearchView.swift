//
//  SearchView.swift
//  Kalsmritikosh
//
//  Faceted + FTS5 search over chunks. M4 covers chunk hits;
//  M5 adds entity/event filters.
//
//  COMPETITOR-DNA (2026-08-19) — Batch search, the pattern ICIJ's Datashare
//  proved on the Pandora Papers: search a whole LIST at once (every name on
//  a roster, every account number) and see hits-per-query at a glance,
//  instead of running hundreds of single searches and missing the ones you
//  didn't think to try.
//

import SwiftUI

/// Pure parsing of a pasted batch list — one query per line, trimmed,
/// blanks dropped, duplicates removed (first occurrence wins).
public nonisolated enum BatchSearchParser {
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

public struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var hits: [Chunk] = []
    @State private var searching = false
    /// Chunks the user soft-excluded this session (greyed with a Restore).
    @State private var excludedIDs: Set<Chunk.ID> = []

    // Batch search (the Datashare pattern).
    @State private var batchMode = false
    @State private var batchInput = ""
    @State private var batchResults: [(query: String, count: Int)] = []
    @State private var batchRunning = false
    @State private var batchProgress = 0

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $batchMode) {
                Text("Search").tag(false)
                Text("Batch list").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .padding(.top, 10)
            .help("Batch list searches many terms at once — every name on a roster, every account number — and shows hits per term")
            if batchMode {
                batchPanel
            } else if hits.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .background(AuroraBackdrop(intensity: 0.6))
        .onAppear { consumePendingQuery() }
        .onChange(of: appState.pendingSearchQuery) { _, _ in consumePendingQuery() }
    }

    // MARK: Batch search

    private var batchPanel: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("One search per line")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $batchInput)
                    .font(.callout.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Paste a whole list — names, companies, account or policy numbers — and search them all at once. You'll see which ones your archive actually mentions, including the ones you'd never have searched by hand.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        runBatch()
                    } label: {
                        Label(batchRunning
                              ? "Searching… \(batchProgress)/\(BatchSearchParser.parse(batchInput).count)"
                              : "Search all", systemImage: "text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(batchRunning || BatchSearchParser.parse(batchInput).isEmpty)
                    if !batchResults.isEmpty {
                        Text("\(batchResults.filter { $0.count > 0 }.count) of \(batchResults.count) terms found")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 280, idealWidth: 340)

            VStack(alignment: .leading, spacing: 6) {
                if batchResults.isEmpty {
                    Spacer()
                    Text("Results appear here — one row per term, hits at a glance.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(batchResults.sorted { $0.count > $1.count }, id: \.query) { row in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(row.count > 0 ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(row.query).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text(row.count >= batchCountCap ? "\(batchCountCap)+" : "\(row.count)")
                                        .font(.callout.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(row.count > 0 ? .primary : .tertiary)
                                    Button("Open") {
                                        batchMode = false
                                        query = row.query
                                        runSearch()
                                    }
                                    .controlSize(.small)
                                    .disabled(row.count == 0)
                                    .help("See the actual passages for this term")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var batchCountCap: Int { 200 }

    private func runBatch() {
        let queries = BatchSearchParser.parse(batchInput)
        guard !queries.isEmpty, let chunks = appState.chunks else { return }
        batchRunning = true
        batchProgress = 0
        batchResults = []
        Task {
            var rows: [(String, Int)] = []
            for q in queries {
                let results = (try? await chunks.searchFTS(q, limit: batchCountCap)) ?? []
                let visible = await appState.screenAuthorizer?.filterChunks(results, boundary: .globalOwner) ?? []
                rows.append((q, visible.count))
                await MainActor.run {
                    batchProgress += 1
                    batchResults = rows
                }
            }
            await MainActor.run { batchRunning = false }
        }
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
