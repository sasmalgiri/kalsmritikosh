//
//  EmailThreadsView.swift
//  Kalsmritikosh
//
//  Dedup + threading over a large ingested email dump (see
//  EmailThreadingService). Collapses exact duplicates and groups scattered
//  replies into conversations, newest-active first.
//

import SwiftUI

public struct EmailThreadsView: View {
    @Environment(AppState.self) private var appState

    @State private var result: EmailThreadingResult?
    @State private var loading = true
    @State private var query = ""

    public init() {}

    private var filteredThreads: [EmailThread] {
        guard let threads = result?.threads else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return threads }
        return threads.filter {
            $0.displaySubject.lowercased().contains(q)
            || $0.participants.contains { $0.lowercased().contains(q) }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if (result?.threads.isEmpty ?? true) {
                    ContentUnavailableView("No email found",
                        systemImage: "envelope.badge.person.crop",
                        description: Text("Ingest a mailbox (mbox, eml, msg, pst…) and its messages will be deduplicated and threaded here."))
                } else if let result {
                    summaryStrip(result)
                    TextField("Filter by subject or participant", text: $query)
                        .textFieldStyle(.roundedBorder)
                    threadList
                    disclaimer
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Email Threads")
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Email threads", systemImage: "envelope.badge.person.crop")
                .font(.title2.bold())
            Text("A large email dump, made navigable — exact duplicates removed and scattered replies grouped into conversations, most-recently-active first.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryStrip(_ r: EmailThreadingResult) -> some View {
        HStack(spacing: 16) {
            card("\(r.threads.count)", "conversations", .blue)
            card("\(r.totalMessages)", "messages", .teal)
            card("\(r.duplicatesRemoved)", "duplicates removed", .orange)
        }
    }

    private func card(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(v).font(.title.bold()).foregroundStyle(c)
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(c.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(filteredThreads) { thread in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(thread.messages) { msg in
                            messageRow(msg)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    threadHeader(thread)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func threadHeader(_ thread: EmailThread) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(thread.displaySubject).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text("\(thread.count) msg").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(thread.participants.prefix(3).joined(separator: ", "))
                    .lineLimit(1)
                if thread.participants.count > 3 {
                    Text("+\(thread.participants.count - 3)")
                }
                Spacer()
                if let range = dateRange(thread) { Text(range) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func messageRow(_ msg: EmailDigestRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(msg.from.isEmpty ? "(unknown sender)" : msg.from)
                    .font(.caption.bold()).lineLimit(1)
                Spacer()
                Text(msg.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "undated")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(msg.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How threading works").font(.subheadline.bold())
            Text("Duplicates are detected by exact file content — identical bytes are collapsed to one. Conversations are grouped by subject with reply/forward prefixes stripped, then ordered by date. This is subject-based threading: the archive doesn't store the email Message-ID / In-Reply-To headers that would let two unrelated \"Re: update\" chains be told apart, so treat a thread as a strong grouping, not a guarantee.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func dateRange(_ thread: EmailThread) -> String? {
        guard let e = thread.earliest else { return nil }
        let f: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) }
        if let l = thread.latest, Calendar.current.isDate(e, inSameDayAs: l) == false {
            return "\(f(e)) – \(f(l))"
        }
        return f(e)
    }

    private func load() async {
        loading = true
        guard let repo = appState.objects else { loading = false; return }
        let rows = (try? await repo.emailDigests()) ?? []
        result = EmailThreadingService.organize(rows)
        loading = false
    }
}
