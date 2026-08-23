//
//  TrendsView.swift
//  Kalsmritikosh
//
//  Cross-case trend analytics over the whole ledger — the "surface recurring
//  patterns across all my work" wish (HR/SIU/legal). Shows activity over time,
//  what kinds of events dominate, and the shape of the entity population. All
//  read-only aggregates over the one ledger; nothing is inferred or invented.
//

import SwiftUI
import Charts

public struct TrendsView: View {
    @Environment(AppState.self) private var appState

    struct YearBucket: Identifiable { let id = UUID(); let year: Int; let count: Int }
    struct Slice: Identifiable { let id = UUID(); let label: String; let count: Int }

    @State private var byYear: [YearBucket] = []
    @State private var eventKinds: [Slice] = []
    @State private var entityKinds: [Slice] = []
    @State private var totalEvents = 0
    @State private var loading = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if totalEvents == 0 && entityKinds.isEmpty {
                    ContentUnavailableView("Nothing to chart yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Ingest and process some documents and their trends will appear here."))
                } else {
                    if !byYear.isEmpty { activityChart }
                    if !eventKinds.isEmpty { eventKindChart }
                    if !entityKinds.isEmpty { entityKindChart }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Trends")
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Trends", systemImage: "chart.xyaxis.line")
                .font(.title2.bold())
            Text("Patterns across everything you've ingested — when activity happened, what kinds of events dominate, and the makeup of the people and organizations involved.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dated events over time").font(.headline)
            Chart(byYear) { b in
                BarMark(x: .value("Year", String(b.year)), y: .value("Events", b.count))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 220)
            Text("\(totalEvents) dated events across \(byYear.count) year(s).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var eventKindChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event types").font(.headline)
            Chart(eventKinds) { s in
                BarMark(x: .value("Count", s.count), y: .value("Type", s.label))
                    .foregroundStyle(Color.teal)
            }
            .frame(height: max(120, CGFloat(eventKinds.count) * 30))
        }
    }

    private var entityKindChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entity population").font(.headline)
            Chart(entityKinds) { s in
                BarMark(x: .value("Count", s.count), y: .value("Kind", s.label))
                    .foregroundStyle(Color.indigo)
            }
            .frame(height: max(120, CGFloat(entityKinds.count) * 30))
        }
    }

    private func load() async {
        loading = true

        // Events: bucket by year + count by kind.
        var events: [Event] = []
        if let repo = appState.events {
            events = (try? await repo.recent(limit: 5_000)) ?? []
        }
        totalEvents = events.count
        let cal = Calendar(identifier: .gregorian)
        var yearCounts: [Int: Int] = [:]
        var kindCounts: [String: Int] = [:]
        for e in events {
            let y = cal.component(.year, from: e.date)
            if y > 1000 && y < 3000 { yearCounts[y, default: 0] += 1 }
            kindCounts[prettyEventKind(e.kind), default: 0] += 1
        }
        byYear = yearCounts.map { YearBucket(year: $0.key, count: $0.value) }.sorted { $0.year < $1.year }
        eventKinds = kindCounts.map { Slice(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }.prefix(10).map { $0 }

        // Entities: count by kind (skip empties).
        var entRows: [Slice] = []
        if let repo = appState.entities {
            for kind in Entity.Kind.allCases {
                let c = (try? await repo.count(of: kind)) ?? 0
                if c > 0 { entRows.append(Slice(label: prettyEntityKind(kind), count: c)) }
            }
        }
        entityKinds = entRows.sorted { $0.count > $1.count }.prefix(12).map { $0 }

        loading = false
    }

    private func prettyEventKind(_ k: Event.Kind) -> String {
        k.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
    private func prettyEntityKind(_ k: Entity.Kind) -> String {
        k.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

#if DEBUG
#Preview("Trends — empty") {
    TrendsView()
        .environment(AppState())
        .frame(width: 940, height: 720)
}
#endif
