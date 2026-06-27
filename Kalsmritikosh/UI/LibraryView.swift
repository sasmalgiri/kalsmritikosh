//
//  LibraryView.swift
//  Kalsmritikosh
//
//  HISTORY Phase E.2 — the topic library. Lists the Phase B.2
//  detected communities and their LLM-derived summaries (B.3). Each
//  row is clickable: tapping pre-seeds the History tab with a
//  "Tell me the story of <topic>" question.
//
//  This is the "book index" surface — the user can see at a glance
//  what major topics exist in their archive without typing a query.
//

import SwiftUI

public struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var topics: [TopicMatch] = []
    @State private var loading = true
    @State private var lastError: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.tint)
            Text("Library")
                .font(.headline)
            Spacer()
            Text("\(topics.count) topics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading topics…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = lastError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if topics.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "book.pages")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("No topics yet.").font(.title3.weight(.medium))
                Text("Topic communities form once your archive has been classified and the summarizer has run. Ingest more data or wait for the next scheduled pass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(topics, id: \.communityID) { topic in
                        topicRow(topic)
                    }
                }
                .padding(14)
            }
        }
    }

    private func topicRow(_ topic: TopicMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(topic.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(topic.memberCount) members")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(topic.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }
        guard let retriever = appState.topicRetriever else {
            lastError = "Topic retriever not ready yet."
            return
        }
        topics = await retriever.listTopics(limit: 200)
    }
}
