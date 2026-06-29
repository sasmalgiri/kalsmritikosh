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
    /// Phase J.18 — zoom level for the row grouping. The user picks
    /// Day / Month / Year / Decade and the section headers change
    /// accordingly, letting them collapse the same event set across
    /// scales without re-fetching.
    @State private var zoom: ZoomLevel = .month
    /// Phase J.20 — version count per event, polled lazily so the
    /// row's version badge can light up without re-querying on every
    /// scroll.
    @State private var versionCountByEvent: [Event.ID: Int] = [:]
    /// Phase J.20 — when set, opens the version-diff sheet for the
    /// given event.
    @State private var versionSheetEvent: Event?
    /// Phase J.22 — when set, opens the full Event detail sheet.
    @State private var detailSheetEvent: Event?

    public enum ZoomLevel: String, CaseIterable, Identifiable {
        case day, month, year, decade
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .day:    return "Day"
            case .month:  return "Month"
            case .year:   return "Year"
            case .decade: return "Decade"
            }
        }
    }

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
                    ForEach(groupedByZoom(), id: \.0) { header, bucket in
                        Section(header) {
                            ForEach(bucket) { event in
                                row(for: event)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await refresh() }
        .task(id: events.map(\.id)) { await loadVersionCounts() }
        .sheet(item: $versionSheetEvent) { ev in
            EventVersionDiffSheet(event: ev) { versionSheetEvent = nil }
                .environment(appState)
        }
        .sheet(item: $detailSheetEvent) { ev in
            EventDetailSheet(event: ev) { detailSheetEvent = nil }
                .environment(appState)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
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
            HStack {
                Text("Zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Zoom", selection: $zoom) {
                    ForEach(ZoomLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
    /// Phase J.16 — DatePrecision-aware label. Shows "On Mar 14,
    /// 2025" / "in March 2025" / "during 2025" / "in the 2020s"
    /// instead of pretending every event is day-precise. The `~`
    /// prefix is still added when the *confidence* in the date is
    /// low, independent of precision.
    static func formatDate(_ event: Event) -> String {
        let phrase = event.datePrecision.renderPhrase(date: event.date)
        let trimmed = phrase
            .replacingOccurrences(of: "On ", with: "")
            .replacingOccurrences(of: "in ", with: "")
            .replacingOccurrences(of: "during ", with: "")
            .replacingOccurrences(of: " at ", with: " ")
        return event.dateConfidence < 0.6 ? "~ \(trimmed)" : trimmed
    }

    private func row(for event: Event) -> some View {
        HStack(alignment: .top) {
            Text(Self.formatDate(event))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
                .help(Self.dateTooltip(event))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.body)
                if let summary = event.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                confidenceOverlay(event)
            }
            Spacer()
            if let count = versionCountByEvent[event.id], count >= 2 {
                Button {
                    versionSheetEvent = event
                } label: {
                    Label("\(count)", systemImage: "clock.arrow.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("\(count) version\(count == 1 ? "" : "s") on file — tap to view the change history.")
            }
            Text(event.kind.rawValue)
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            detailSheetEvent = event
        }
    }

    /// Phase J.20 — poll the event_versions table once per refresh
    /// so the row badge can show how many edits each event has
    /// accumulated. Cheap single COUNT-per-event would be N queries;
    /// this batches into one GROUP BY.
    private func loadVersionCounts() async {
        guard let db = appState.database, !events.isEmpty else { return }
        let ids = events.map(\.id)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? await db.query("""
        SELECT event_id, COUNT(*) FROM event_versions
        WHERE event_id IN (\(placeholders))
        GROUP BY event_id;
        """, ids.map { .uuid($0) })) ?? []
        var counts: [Event.ID: Int] = [:]
        for row in rows {
            guard let id = row.uuid(0), let c = row.int(1) else { continue }
            counts[id] = Int(c)
        }
        await MainActor.run { self.versionCountByEvent = counts }
    }

    /// Phase J.16 — per-event confidence overlay. Two-color bar:
    /// blue half is `confidence` (semantic), purple half is
    /// `dateConfidence` (when the event happened). The tooltip
    /// spells out the precision tier so the user understands why a
    /// 2025-quarter event isn't "exactly March 14."
    @ViewBuilder
    private func confidenceOverlay(_ event: Event) -> some View {
        HStack(spacing: 6) {
            confidenceBar(value: event.confidence.value, tint: .blue, label: "ev")
            confidenceBar(value: event.dateConfidence, tint: .purple, label: "date")
            Text(event.datePrecision.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func confidenceBar(value: Double, tint: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.7))
                        .frame(width: proxy.size.width * value, height: 4)
                }
            }
            .frame(width: 48, height: 4)
            Text(String(format: "%.0f", value * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func dateTooltip(_ event: Event) -> String {
        var lines: [String] = []
        lines.append("Precision: \(event.datePrecision.displayName)")
        lines.append(String(format: "Date confidence: %.0f%%", event.dateConfidence * 100))
        lines.append(String(format: "Event confidence: %.0f%%", event.confidence.value * 100))
        if event.dateConfidence < 0.6 {
            lines.append("(Approximate — system flagged low date confidence.)")
        }
        return lines.joined(separator: "\n")
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
        groupedByZoom()
    }

    /// Phase J.18 — zoom-aware grouping. Same event list, different
    /// section headers depending on the picker. Day grouping shows
    /// "Mon, Mar 14, 2025", Month "March 2025", Year "2025",
    /// Decade "2020s".
    private func groupedByZoom() -> [(String, [Event])] {
        let fmt = DateFormatter()
        let calendar = Calendar.current
        switch zoom {
        case .day:    fmt.dateFormat = "EEE, MMM d, yyyy"
        case .month:  fmt.dateFormat = "MMMM yyyy"
        case .year:   fmt.dateFormat = "yyyy"
        case .decade: fmt.dateFormat = "yyyy"
        }
        let groups = Dictionary(grouping: events) { event -> String in
            switch zoom {
            case .decade:
                let year = calendar.component(.year, from: event.date)
                let decadeStart = (year / 10) * 10
                return "\(decadeStart)s"
            default:
                return fmt.string(from: event.date)
            }
        }
        return groups.sorted {
            ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast)
        }
    }
}

/// Phase J.20 — Vol 25 ¶10 / Vol 17 §A6 SCD2 chain viewer. Reads
/// every version row for an event and renders the chain oldest →
/// newest with per-field diffs against the previous version.
private struct EventVersionDiffSheet: View {
    let event: Event
    let onClose: () -> Void
    @Environment(AppState.self) private var appState
    @State private var versions: [EventVersion] = []
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                Text("Event change history")
                    .font(.headline)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Text(event.title)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            Divider()
            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading version chain…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if versions.isEmpty {
                Text("No version history recorded — this event has only its initial state.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { idx, version in
                            versionCard(idx: idx, version: version,
                                        previous: idx > 0 ? versions[idx - 1] : nil)
                        }
                    }
                }
                .frame(minHeight: 280, maxHeight: 480)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await load() }
    }

    @ViewBuilder
    private func versionCard(idx: Int, version: EventVersion, previous: EventVersion?) -> some View {
        let dateFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("v\(version.version)")
                    .font(.callout.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: .capsule)
                    .foregroundStyle(.orange)
                Text(version.agent)
                    .font(.caption.monospaced())
                Spacer()
                Text(dateFmt.string(from: version.recordedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if version.validTo == nil {
                    Text("current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            if let activity = version.activity {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = version.reason {
                Text(reason)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            }
            diffRows(current: version, previous: previous)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func diffRows(current: EventVersion, previous: EventVersion?) -> some View {
        let curPayload = current.payload
        let prevPayload = previous?.payload
        VStack(alignment: .leading, spacing: 3) {
            diffRow("title", current: curPayload.title, previous: prevPayload?.title)
            diffRow("kind", current: curPayload.kind.rawValue, previous: prevPayload?.kind.rawValue)
            diffRow("date",
                    current: curPayload.datePrecision.renderPhrase(date: curPayload.date),
                    previous: prevPayload.map { $0.datePrecision.renderPhrase(date: $0.date) })
            diffRow("precision",
                    current: curPayload.datePrecision.displayName,
                    previous: prevPayload?.datePrecision.displayName)
            diffRow("date conf",
                    current: String(format: "%.0f%%", curPayload.dateConfidence * 100),
                    previous: prevPayload.map { String(format: "%.0f%%", $0.dateConfidence * 100) })
            if let summary = curPayload.summary, !summary.isEmpty {
                diffRow("summary", current: summary, previous: prevPayload?.summary, maxLines: 3)
            }
        }
    }

    @ViewBuilder
    private func diffRow(_ label: String, current: String, previous: String?, maxLines: Int = 1) -> some View {
        let changed = previous != nil && previous != current
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(current)
                .font(.caption)
                .lineLimit(maxLines)
                .foregroundStyle(changed ? .primary : .secondary)
                .strikethrough(false)
            if changed, let prev = previous {
                Text("(was \(prev))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(maxLines)
            }
        }
    }

    private func load() async {
        guard let repo = appState.eventVersions else {
            await MainActor.run { self.loading = false }
            return
        }
        let list = (try? await repo.versions(of: event.id)) ?? []
        await MainActor.run {
            self.versions = list
            self.loading = false
        }
    }
}
