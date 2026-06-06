//
//  TimelineView.swift
//  Kalsmritikosh
//
//  Vertical event timeline grouped by year/month. Picker selects
//  view scope (global / financial / project / person / company).
//

import SwiftUI

public struct TimelineView: View {
    @Environment(AppState.self) private var appState

    @State private var scopeIndex: Int = 0
    @State private var scopeName: String = ""
    @State private var events: [Event] = []
    @State private var loading = false

    private let scopes = ["Global", "Financial", "Project", "Person", "Company"]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if events.isEmpty {
                placeholder
            } else {
                List {
                    ForEach(groupedByMonth(), id: \.0) { month, monthEvents in
                        Section(month) {
                            ForEach(monthEvents) { event in
                                row(for: event)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await refresh() }
    }

    private var controls: some View {
        HStack {
            Picker("Scope", selection: $scopeIndex) {
                ForEach(0..<scopes.count, id: \.self) { i in
                    Text(scopes[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if scopeIndex >= 2 {
                TextField("Name", text: $scopeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            Button("Refresh") {
                Task { await refresh() }
            }
        }
        .padding()
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Timeline").font(.title2)
            Text("Ingest a folder and Atlas will reconstruct events here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// T9 — Prepend "~" to dates we don't fully trust (mtime-fallback,
    /// roughly anything below the 0.6 threshold).
    static func formatDate(_ event: Event) -> String {
        let formatted = event.date.formatted(date: .abbreviated, time: .omitted)
        return event.dateConfidence < 0.6 ? "~ \(formatted)" : formatted
    }

    private func row(for event: Event) -> some View {
        HStack(alignment: .top) {
            Text(Self.formatDate(event))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
                .help(event.dateConfidence < 0.6
                    ? "Approximate date — low date confidence (\(String(format: "%.2f", event.dateConfidence)))"
                    : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body)
                if let summary = event.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.kind.rawValue)
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        guard let engine = appState.timelineEngine else { return }
        loading = true
        let view = currentView()
        let results = (try? await engine.reconstruct(view)) ?? []
        await MainActor.run {
            self.events = results
            self.loading = false
        }
    }

    private func currentView() -> TimelineEngine.View {
        switch scopeIndex {
        case 1: return .financial
        case 2: return .project(scopeName)
        case 3: return .person(scopeName)
        case 4: return .company(scopeName)
        default: return .global
        }
    }

    private func groupedByMonth() -> [(String, [Event])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        let groups = Dictionary(grouping: events) { event -> String in
            fmt.string(from: event.date)
        }
        return groups.sorted { $0.value.first?.date ?? .distantPast > $1.value.first?.date ?? .distantPast }
    }
}
