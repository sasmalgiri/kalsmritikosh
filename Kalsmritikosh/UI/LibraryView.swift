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
    /// HISTORY follow-on — when the user taps a topic, this opens
    /// a sheet that runs the reconstructive composer scoped to the
    /// topic's title. Sheet hosts a stripped HistoryView body.
    @State private var openedTopic: TopicMatch?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reload() }
        .sheet(item: $openedTopic) { topic in
            TopicReconstructionSheet(topic: topic) {
                openedTopic = nil
            }
            .environment(appState)
            .frame(minWidth: 720, minHeight: 540)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Library")
                    .font(Theme.display(28, .bold))
                Text("Topics discovered across your archive — tap one to reconstruct the story of that subject.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            .scrollContentBackground(.hidden)
        }
    }

    private func topicRow(_ topic: TopicMatch) -> some View {
        Button {
            openedTopic = topic
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(topic.memberCount) members")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(topic.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    /// Reuses the brain's streaming path so the sheet renders chapter
    /// cards as they arrive, just like the History tab does.
    private struct TopicReconstructionSheet: View {
        @Environment(AppState.self) private var appState
        let topic: TopicMatch
        let onClose: () -> Void
        @State private var chapters: [NarrativeChapter] = []
        @State private var finalAnswer: VerifiedAnswer?
        @State private var streaming = false

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title).font(.title3.weight(.semibold))
                        Text("\(topic.memberCount) members").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if streaming { ProgressView().controlSize(.small) }
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(topic.summary).font(.body).foregroundStyle(.secondary)
                        ForEach(chapters) { chapter in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(chapter.title).font(.headline)
                                if !chapter.prose.isEmpty {
                                    Text(chapter.prose).font(.body).textSelection(.enabled)
                                } else {
                                    Text("(\(chapter.eventIDs.count) events recorded.)")
                                        .font(.callout.italic())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(8)
                        }
                        if let answer = finalAnswer, !answer.contradictions.isEmpty {
                            ForEach(answer.contradictions, id: \.description) { c in
                                Label(c.description, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .task { await run() }
        }

        private func run() async {
            guard !streaming else { return }
            streaming = true
            defer { streaming = false }
            let q = "Tell me the story of \(topic.title)."
            for await update in await appState.brain.answerStream(question: q,
                                                                   access: SensitiveAccessContext(scope: .globalOwnerRetrieval())) {
                switch update {
                // AEE-M2 — chapters stream as analysisProgress artifacts; terminal = verifiedFinal/incomplete.
                case .analysisProgress(_, let chapter):
                    if let chapter { await MainActor.run { chapters.append(chapter) } }
                case .verifiedFinal(let a), .incomplete(let a):
                    await MainActor.run { finalAnswer = a }
                case .chapterReady(let c):   // legacy compat
                    await MainActor.run { chapters.append(c) }
                case .verified(let a):       // legacy compat
                    await MainActor.run { finalAnswer = a }
                default:
                    continue
                }
            }
        }
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
