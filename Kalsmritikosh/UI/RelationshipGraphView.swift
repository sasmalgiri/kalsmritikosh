//
//  RelationshipGraphView.swift
//  Kalsmritikosh
//
//  W3-3 — an interactive timeline of dated events and a graph of people and
//  organisations. Every point and line opens its evidence.
//

import SwiftUI
import Charts
import os

struct GraphNode: Identifiable, Hashable { let id: UUID; let name: String; let weight: Int }
struct GraphEdge: Identifiable, Hashable { let id: String; let a: UUID; let b: UUID; let kind: String; let count: Int }

extension AppState {
    func relationshipGraph(limit: Int = 40) async -> (nodes: [GraphNode], edges: [GraphEdge]) {
        guard let database else { return ([], []) }
        do {
            let edgeRows = try await database.query("""
                SELECT r.from_entity_id, r.to_entity_id, r.kind, COUNT(*) FROM relationships r
                JOIN entities a ON a.id = r.from_entity_id JOIN entities b ON b.id = r.to_entity_id
                WHERE a.merged_into IS NULL AND b.merged_into IS NULL
                GROUP BY r.from_entity_id, r.to_entity_id, r.kind ORDER BY COUNT(*) DESC LIMIT 400;
                """, [])
            var degree: [UUID: Int] = [:]
            var edges: [GraphEdge] = []
            for r in edgeRows {
                guard let a = r.uuid(0), let b = r.uuid(1) else { continue }
                let c = Int(r.int(3) ?? 1)
                degree[a, default: 0] += c; degree[b, default: 0] += c
                edges.append(GraphEdge(id: "\(a)-\(b)-\(r.string(2) ?? "")", a: a, b: b, kind: r.string(2) ?? "related", count: c))
            }
            let top = Set(degree.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
            var nodes: [GraphNode] = []
            for id in top {
                let name = try await database.query("SELECT value FROM entities WHERE id = ?;", [.uuid(id)]).first?.string(0) ?? "?"
                nodes.append(GraphNode(id: id, name: name, weight: degree[id] ?? 1))
            }
            return (nodes.sorted { $0.weight > $1.weight }, edges.filter { top.contains($0.a) && top.contains($0.b) })
        } catch {
            KalsmritikoshLog.app.error("Graph load failed: \(error.localizedDescription, privacy: .public)")
            return ([], [])
        }
    }

    func evidenceDocuments(between a: UUID, and b: UUID?) async -> [String] {
        guard let database else { return [] }
        let rows: [SQLRow]
        if let b {
            rows = (try? await database.query("""
                SELECT DISTINCT f.url FROM relationships r JOIN knowledge_objects ko ON ko.id = r.source_object_id
                JOIN files f ON f.id = ko.file_id
                WHERE (r.from_entity_id = ? AND r.to_entity_id = ?) OR (r.from_entity_id = ? AND r.to_entity_id = ?) LIMIT 30;
                """, [.uuid(a), .uuid(b), .uuid(b), .uuid(a)])) ?? []
        } else {
            rows = (try? await database.query("""
                SELECT DISTINCT f.url FROM entity_mentions m JOIN knowledge_objects ko ON ko.id = m.source_object_id
                JOIN files f ON f.id = ko.file_id WHERE m.entity_id = ? LIMIT 30;
                """, [.uuid(a)])) ?? []
        }
        return rows.compactMap { $0.string(0) }.map { URL(string: $0)?.lastPathComponent ?? $0 }
    }
}

struct RelationshipGraphView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var canvasSize: CGSize = .zero
    @State private var selected: GraphNode?
    @State private var selectedPair: (a: UUID, b: UUID)?
    @State private var evidence: [String] = []
    @State private var pairTimeline: [PairTimelineItem] = []
    @State private var pairLoading = false
    @State private var events: [ChronologyEntry] = []
    @State private var tab = 0
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var openSource: CitationOpenTarget?

    private let zoomRange: ClosedRange<CGFloat> = 0.4...3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) { Text("Relationships").tag(0); Text("Timeline").tag(1) }
                .pickerStyle(.segmented).frame(width: 280)
            if tab == 0 { graph } else { timeline }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .task { await load() }
        .sheet(item: $openSource) { target in
            CitationSourceSheet(target: target) { openSource = nil }
        }
    }

    // MARK: Graph (force-directed; drag a name to move it, pinch or the buttons to zoom, drag the background to pan)

    private var graph: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                zoomControls
                GeometryReader { geo in
                    ZStack {
                        Canvas { ctx, _ in
                            for e in edges {
                                guard let p = positions[e.a], let q = positions[e.b] else { continue }
                                var path = Path(); path.move(to: p); path.addLine(to: q)
                                let isSelected = selectedPair.map { Set([$0.a, $0.b]) == Set([e.a, e.b]) } ?? false
                                ctx.stroke(path, with: .color(isSelected ? .accentColor : .secondary.opacity(0.35)),
                                           lineWidth: isSelected ? 3 : min(4, 0.5 + Double(e.count) * 0.3))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(coordinateSpace: .named("relationshipGraph")).onEnded { v in
                            selectEdge(near: v.location)
                        })
                        .simultaneousGesture(panGesture)
                        ForEach(nodes) { n in
                            if let p = positions[n.id] {
                                Text(n.name)
                                    .font(.caption2).lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(selected == n ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), in: Capsule())
                                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("relationshipGraph"))
                                        .onChanged { v in positions[n.id] = clamp(v.location) })
                                    .onTapGesture { select(n) }
                                    .accessibilityLabel("\(n.name), \(n.weight) links")
                                    .accessibilityHint("Drag to move. Select to see its relationships.")
                                    .position(p)
                            }
                        }
                    }
                    .coordinateSpace(name: "relationshipGraph")
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(MagnifyGesture()
                        .onChanged { v in
                            let base = pinchBase ?? zoom
                            pinchBase = base
                            zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, base * v.magnification))
                        }
                        .onEnded { _ in pinchBase = nil })
                    .onAppear { canvasSize = geo.size; if positions.isEmpty { place(in: geo.size) } }
                    .onChange(of: nodes) { _, _ in place(in: geo.size) }
                    .onChange(of: geo.size) { _, s in canvasSize = s }
                }
                .clipped()
                .frame(minWidth: 560, minHeight: 440)
            }
            sidePanel.frame(width: 280)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.25) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass").labelStyle(.iconOnly) }
                .help("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass").labelStyle(.iconOnly) }
                .help("Zoom in")
            Button("Fit") { zoom = 1; pan = .zero }.help("Reset zoom and pan")
            Button("Re-arrange") { place(in: canvasSize) }.help("Lay the chart out again (force-directed)")
            Spacer()
            Text("Drag a name to move it · click a line for the two parties' timeline")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                let base = panBase ?? pan
                panBase = base
                pan = CGSize(width: base.width + v.translation.width, height: base.height + v.translation.height)
            }
            .onEnded { _ in panBase = nil }
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let pair = selectedPair {
                    pairPanel(pair)
                } else {
                    Text(selected?.name ?? "Select a name or a line").font(.headline)
                    if let s = selected {
                        let linked = edges.filter { $0.a == s.id || $0.b == s.id }
                        Text("\(linked.count) relationship\(linked.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        ForEach(linked.prefix(12)) { e in
                            let other = name(e.a == s.id ? e.b : e.a)
                            Button("\(e.kind): \(other) (\(e.count))") { selectPair(e.a, e.b) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    Divider()
                    Text("Evidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(evidence, id: \.self) { Text($0).font(.caption2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pairPanel(_ pair: (a: UUID, b: UUID)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { selectedPair = nil; pairTimeline = [] } label: { Label("Back", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.borderless)
                Spacer()
            }
            Text("\(name(pair.a)) ↔ \(name(pair.b))").font(.headline).fixedSize(horizontal: false, vertical: true)
            let kinds = edges.filter { Set([$0.a, $0.b]) == Set([pair.a, pair.b]) }.map { "\($0.kind) (\($0.count))" }
            if !kinds.isEmpty { Text(kinds.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("Communication timeline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if pairLoading {
                ProgressView().controlSize(.small)
            } else if pairTimeline.isEmpty {
                Text("No dated emails or events between these two are in the ledger.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(pairTimeline) { item in timelineRow(item, pair: pair) }
            }
            Divider()
            Text("Documents behind the relationship").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(evidence, id: \.self) { Text($0).font(.caption2) }
        }
    }

    private func timelineRow(_ item: PairTimelineItem, pair: (a: UUID, b: UUID)) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.kind == .email ? "envelope" : "calendar")
                    .foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.date.map { $0.formatted(date: .abbreviated, time: item.kind == .email ? .shortened : .omitted) } ?? "Date not readable")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                    if let first = item.fromFirst {
                        Text(first ? "\(name(pair.a)) → \(name(pair.b))" : "\(name(pair.b)) → \(name(pair.a))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .disabled(item.sourceObjectID == nil)
        .help(item.sourceObjectID == nil ? "No source recorded" : "Open the source")
    }

    private var timeline: some View {
        Chart(events) { e in
            PointMark(x: .value("Date", e.date), y: .value("Kind", e.source))
                .annotation(position: .top, alignment: .leading) { Text(e.title).scaledFont(8, relativeTo: .caption).lineLimit(1) }
        }
        .frame(minHeight: 460)
    }

    // MARK: Actions

    private func name(_ id: UUID) -> String { nodes.first { $0.id == id }?.name ?? "?" }

    private func setZoom(_ z: CGFloat) { zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, z)) }

    private func clamp(_ p: CGPoint) -> CGPoint {
        guard canvasSize.width > 40, canvasSize.height > 40 else { return p }
        return CGPoint(x: min(canvasSize.width - 20, max(20, p.x)), y: min(canvasSize.height - 20, max(20, p.y)))
    }

    private func select(_ n: GraphNode) {
        selected = n; selectedPair = nil; pairTimeline = []
        Task { evidence = await appState.evidenceDocuments(between: n.id, and: nil) }
    }

    /// The line nearest the click (within a few points) selects that pair.
    private func selectEdge(near p: CGPoint) {
        var best: (GraphEdge, CGFloat)?
        for e in edges {
            guard let a = positions[e.a], let b = positions[e.b] else { continue }
            let d = Self.distance(from: p, toSegment: a, b)
            if d < 8, d < (best?.1 ?? .infinity) { best = (e, d) }
        }
        if let best { selectPair(best.0.a, best.0.b) }
    }

    private func selectPair(_ a: UUID, _ b: UUID) {
        selectedPair = (a, b)
        pairLoading = true
        Task {
            evidence = await appState.evidenceDocuments(between: a, and: b)
            pairTimeline = await loadPairTimeline(a, b)
            pairLoading = false
        }
    }

    private func loadPairTimeline(_ a: UUID, _ b: UUID) async -> [PairTimelineItem] {
        guard let database = appState.database else { return [] }
        do { return try await PairTimeline.load(database, between: a, and: b) } catch {
            KalsmritikoshLog.ui.error("Pair timeline failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func open(_ item: PairTimelineItem) {
        guard let objectID = item.sourceObjectID else { return }
        Task { @MainActor in
            do {
                guard let url = try await appState.objects?.fetchSourceURL(id: objectID) else {
                    KalsmritikoshLog.ui.info("Pair timeline: no source file for \(objectID.uuidString, privacy: .public)")
                    return
                }
                openSource = CitationOpenTarget(url: url, objectID: objectID, quote: nil)
            } catch {
                KalsmritikoshLog.ui.error("Pair timeline source open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func place(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let pts = ForceLayout.layout(nodeCount: nodes.count,
                                     edges: edges.compactMap { e in index[e.a].flatMap { a in index[e.b].map { (a, $0) } } },
                                     size: size)
        positions = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), pts))
    }

    private func load() async {
        let g = await appState.relationshipGraph()
        nodes = g.nodes; edges = g.edges
        // Timeline reuses the chronology loader when issues are available; otherwise plain events.
        if let ev = try? await appState.events?.recent(limit: 300) {
            events = ev.map { ChronologyEntry(id: $0.id, date: $0.date, title: $0.title, summary: $0.summary, source: String(describing: $0.kind), issues: []) }
        }
    }
}
