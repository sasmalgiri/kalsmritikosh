//
//  CaseMapChangesPanel.swift
//  Kalsmritikosh
//
//  Living case map M6/M7 screens: "What changed" (the case's own change feed, its seen position, the records
//  resting on changed evidence), "History" (the baseline, recorded states and milestones, read-only viewing and
//  comparison), "Readiness" (explicit work states, no percentage), and the case overview's "What changed since
//  you last looked". They read the ledger only; nothing is sent anywhere. Marking changes as seen reviews nothing.
//

import SwiftUI
import os

/// The map's services over the app's live services (nil until the ledger is open).
@MainActor
enum CaseMapServiceFactory {
    static func map(_ app: AppState) -> CaseMapService? {
        guard let db = app.database, let files = app.caseFiles, let objects = app.objects else { return nil }
        return CaseMapService(sources: .live(database: db, caseFiles: files, custody: app.investigationCustody, analysis: app.investigationAnalysis,
                                             desk: app.investigationContradictionGap, objects: objects))
    }
}

// MARK: - What changed

struct CaseChangeFeedPanel: View {
    let map: CaseMapWorkspaceModel
    let feedService: CaseChangeFeedService?
    let actor: String
    let close: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What changed in this case").font(.headline)
                Spacer()
                if map.feedLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { if let feedService { await map.refreshFeed(feedService) } } }
                    .disabled(reason: feedService == nil ? "The ledger isn't ready yet." : nil)
            }
            Text("Changes to this case since you last chose “Mark as seen”, each with where it comes from. Seeing a change is not reviewing it: nothing is accepted, decided or reversed from here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                Button("Show the Changes view") { map.go(to: .builtIn(.changes)); close() }
                    .help("The map's Changes view shows the items changed since your seen position and those resting on changed evidence.")
                Spacer()
                Button("Mark as seen") { Task { if let feedService { await map.markSeen(feedService, actor: actor) } } }
                    .disabled(reason: markSeenBlocked)
                    .help("Moves your seen position to now. It does not review, accept or decide anything.")
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 600)
        .task {
            if map.feedViewer == nil { map.feedViewer = actor }
            if map.feed == nil, let feedService { await map.refreshFeed(feedService) }
        }
    }

    private var markSeenBlocked: String? {
        guard let feed = map.feed else { return "The changes have not been read yet." }
        if case .failed = feed.state { return "The changes could not be read, so they cannot be marked as seen." }
        return nil
    }

    @ViewBuilder private var content: some View {
        if let feed = map.feed {
            switch feed.state {
            case .failed(let why):
                Label(why, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("This is not “nothing changed”. Choose Refresh, or look at the case sections and the case log.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .partial(let parts):
                Label("Incomplete: \(parts.map(\.label).joined(separator: ", ")) could not be read. Changes there are not listed; this is not a complete account.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                list(feed)
            case .loaded:
                list(feed)
            }
        } else {
            ProgressView("Reading what changed…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func list(_ feed: CaseChangeFeedLoad) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let seen = feed.seen {
                Text("Seen position: \(seen.seenThrough.formatted(date: .abbreviated, time: .shortened)) (marked by \(seen.seenBy)).").font(.caption)
            } else {
                Text("No seen position yet: everything recorded in this case is listed.").font(.caption)
            }
            if let b = feed.baseline {
                Text("Typed changes are recorded from \(b.formatted(date: .abbreviated, time: .shortened)); earlier ones come from the case log and the records themselves.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if feed.changes.isEmpty {
            Text(feed.failedParts.isEmpty ? "Nothing changed in what was read since your seen position." : "Nothing changed in the parts that could be read.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(feed.changes) { ch in row(ch) }
                if feed.omitted > 0 {
                    Text("\(feed.omitted) older change(s) are not listed here; the case log has them all.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private func row(_ ch: CaseChange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Label(ch.kind.label, systemImage: ch.kind.symbol).font(.caption.weight(.semibold))
                Spacer()
                if let at = ch.recordedAt { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(ch.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(ch.basis.label + (ch.actor.map { " · \($0)" } ?? "")).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let r = ch.record, map.liveProjection?.node(r) != nil {
                    Button("Show on map") { map.reveal(r); close() }.buttonStyle(.link).font(.caption)
                }
                if ch.kind.affectsEvidence, ch.record != nil {
                    Button(expanded.contains(ch.id) ? "Hide what rests on it" : "What rests on it") {
                        if expanded.contains(ch.id) { expanded.remove(ch.id) } else { expanded.insert(ch.id) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            if expanded.contains(ch.id), let r = ch.record, let p = map.liveProjection { impact(CaseChangeImpactAnalysis.impact(of: r, in: p)) }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func impact(_ i: CaseChangeImpact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if i.direct.isEmpty {
                Text("Nothing in the case cites or links to it.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Rests on it directly (\(i.direct.count)) — decisions are kept as recorded; review them:").font(.caption.weight(.semibold))
                ForEach(i.direct) { d in
                    Button { map.reveal(d.node); close() } label: {
                        Text("• \(d.title) — \(d.dependency) [\(d.review.label)]").font(.caption).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                }
            }
            if !i.mayNeedReview.isEmpty {
                Text("Further along the dependency path — may need review (\(i.mayNeedReview.count)):").font(.caption.weight(.semibold))
                ForEach(i.mayNeedReview) { d in
                    Button { map.reveal(d.node); close() } label: { Text("• \(d.title) — \(d.dependency)").font(.caption).multilineTextAlignment(.leading) }
                        .buttonStyle(.plain)
                }
            }
            if let skipped = i.notFollowed { Text(skipped).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !i.complete { Text("The walk stopped before the end; the list is incomplete.").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - History

struct CaseHistoryPanel: View {
    let map: CaseMapWorkspaceModel
    let history: CaseHistoryService?
    let caseID: UUID
    let actor: String
    let close: () -> Void
    @State private var baseline: CaseHistoryBaseline?
    @State private var list: [CaseCheckpointSummary] = []
    @State private var milestoneName = ""
    @State private var status: String?
    @State private var comparison: (String, CaseHistoryComparison)?
    @State private var compareFrom: UUID?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History of this case map").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if let baseline {
                Label(baseline.label, systemImage: "calendar.badge.exclamationmark").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only recorded states can be opened. A recorded state is read-only; “Return to current” brings back the case as it is. Evidence recorded after a state is not in it, whatever the date of the event it describes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Record the current state") { Task { await record(.manual, nil) } }
                    .help("Keeps the map as it is now — its items, links, review states and layout — in this case's encrypted ledger.")
                TextField("Milestone name (e.g. Interviews done)", text: $milestoneName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Name a milestone") { Task { await record(.milestone, milestoneName) } }
                    .disabled(reason: milestoneName.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the milestone a name." : nil)
            }
            .controlSize(.small)
            .disabled(history == nil || map.isHistorical)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if list.isEmpty {
                Text("No state of this case has been recorded yet.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(list.filter { Calendar.current.isDate($0.recordedAt, inSameDayAs: day) }) { cp in checkpointRow(cp) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let cmp = comparison { comparisonView(cmp.0, cmp.1) }
            HStack {
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 780, height: 640)
        .task { await reload() }
    }

    private var days: [Date] {
        Array(Set(list.map { Calendar.current.startOfDay(for: $0.recordedAt) })).sorted(by: >)
    }

    @ViewBuilder private func checkpointRow(_ cp: CaseCheckpointSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cp.title).font(.callout.weight(cp.kind == .milestone ? .semibold : .regular))
                if let e = cp.erasedAt {
                    Text("Content erased \(e.formatted(date: .abbreviated, time: .omitted)) (\(cp.erasedReason ?? "erasure")). It cannot be opened.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(cp.nodeCount) item(s), \(cp.linkCount) link(s) · recorded by \(cp.recordedBy) · digest \(cp.contentDigest.prefix(10))…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if cp.erasedAt == nil {
                Button("Open (read-only)") { Task { await open(cp) } }
                Button(compareFrom == cp.id ? "Choose another…" : "Compare") {
                    if let from = compareFrom, from != cp.id { Task { await compare(from, cp.id) } } else { compareFrom = cp.id }
                }
                Button("Compare with current") { Task { await compareWithCurrent(cp) } }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func comparisonView(_ title: String, _ c: CaseHistoryComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(CaseHistoryComparison.Change.allCases.map { "\($0.label): \(c.count($0))" }.joined(separator: " · ")).font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(c.entries) { e in
                        Text("\(e.change.label) — \(e.isLink ? "link" : "item"): \(e.title). \(e.detail)").font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reload() async {
        guard let history else { status = "The ledger isn't ready yet."; return }
        do {
            baseline = try await history.baseline(caseID: caseID)
            list = try await history.checkpoints(caseID: caseID)
        } catch {
            KalsmritikoshLog.ui.error("Case history not read: \(error.localizedDescription, privacy: .public)")
            status = "The history could not be read: \(error.localizedDescription). This is not an empty history."
        }
    }

    private func record(_ kind: CaseCheckpointKind, _ name: String?) async {
        guard let history else { return }
        busy = true; defer { busy = false }
        do {
            let cp = try await history.record(caseID: caseID, kind: kind, name: name, actor: actor)
            status = "Recorded: \(cp.title)."
            milestoneName = ""
            await reload()
        } catch {
            KalsmritikoshLog.ui.error("Case state not recorded: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }

    private func open(_ cp: CaseCheckpointSummary) async {
        guard let history else { return }
        do {
            let view = try await history.open(id: cp.id, caseID: caseID)
            map.openHistory(view)
            close()
        } catch {
            KalsmritikoshLog.ui.error("Recorded state not opened: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }

    private func compare(_ a: UUID, _ b: UUID) async {
        guard let history else { return }
        compareFrom = nil
        do {
            let x = try await history.open(id: a, caseID: caseID), y = try await history.open(id: b, caseID: caseID)
            let (older, newer) = x.summary.recordedAt <= y.summary.recordedAt ? (x, y) : (y, x)
            comparison = ("From \(older.summary.title) to \(newer.summary.title)", CaseHistoryComparison.compare(older.payload, newer.payload))
        } catch {
            KalsmritikoshLog.ui.error("Recorded states not compared: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }

    private func compareWithCurrent(_ cp: CaseCheckpointSummary) async {
        guard let history, let p = map.liveProjection else { status = "The current case has not been read yet."; return }
        do {
            let x = try await history.open(id: cp.id, caseID: caseID)
            comparison = ("From \(cp.title) to the case now", CaseHistoryComparison.compare(x.payload, CaseCheckpointPayload.make(p, placements: map.placements)))
        } catch {
            KalsmritikoshLog.ui.error("Recorded state not compared: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }
}

// MARK: - Readiness

struct CaseReadinessPanel: View {
    let readiness: CaseReadiness?
    let select: (CaseMapNodeID) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readiness — the state of the work").font(.headline)
            Text("Counts of recorded work states. There is no percentage and no verdict: a bigger map is not a more finished case, and new contrary evidence moves a question back to “needs review”. The case's stage and approvals stay where you recorded them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let r = readiness {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !r.attention.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Needs attention").font(.caption.weight(.semibold))
                                ForEach(r.attention, id: \.self) { Text("• " + $0).font(.caption) }
                            }
                        }
                        ForEach(r.areas) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(a.title).font(.callout.weight(.semibold))
                                ForEach(a.lines) { l in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(l.count)").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                                        Text(l.label).font(.caption)
                                        Spacer()
                                        if let first = l.items.first {
                                            Button("Show") { select(first); close() }.buttonStyle(.link).font(.caption)
                                        }
                                    }
                                }
                                if let n = a.note { Text(n).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                }
            } else {
                Text("Readiness needs the case and its map to be read first.").font(.callout).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Close") { close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(width: 620, height: 560)
    }
}

// MARK: - Case overview: what changed since you last looked

struct CaseChangesOverviewSection: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    @State private var feedService: CaseChangeFeedService?
    @State private var showing = false
    private var map: CaseMapWorkspaceModel { model.map }

    var body: some View {
        CaseSection(title: "What changed since you last looked",
                    subtitle: "This case's own changes since your seen position, with where each comes from. Seeing them is not reviewing them.") {
            VStack(alignment: .leading, spacing: 6) {
                if let feed = map.feed {
                    switch feed.state {
                    case .failed(let why):
                        Label(why, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                    case .partial(let parts):
                        Label("Incomplete: \(parts.map(\.label).joined(separator: ", ")) could not be read.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                        summary(feed)
                    case .loaded:
                        summary(feed)
                    }
                } else if map.feedLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Not read yet.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Show what changed…") { showing = true }
                    .accessibilityIdentifier("case.changes.open")
            }
        }
        .task(id: model.snapshot?.actions.count) { await load() }
        .sheet(isPresented: $showing) {
            CaseChangeFeedPanel(map: map, feedService: feedService, actor: model.actor) { showing = false }
        }
    }

    @ViewBuilder private func summary(_ feed: CaseChangeFeedLoad) -> some View {
        let new = feed.newChanges
        if new.isEmpty {
            Text("Nothing changed in what was read since your seen position.").font(.caption).foregroundStyle(.secondary)
        } else {
            // S6 (CHANGE-06): every group, with how much rests on it and what is unresolved — nothing folded away.
            let groups = map.liveProjection.map { CaseChangeDigest.groups(feed, projection: $0) } ?? []
            ForEach(groups) { g in
                Label(g.line, systemImage: g.kind.symbol).font(.caption)
            }
            if feed.omitted > 0 { Text("\(feed.omitted) older change(s) beyond the list are counted in “Show what changed…”.").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        guard let db = appState.database else { return }
        if feedService == nil { feedService = CaseChangeFeedService(database: db) }
        if map.liveProjection == nil, let service = CaseMapServiceFactory.map(appState) { await map.refresh(service) }
        if let feedService { await map.refreshFeed(feedService) }
    }
}
