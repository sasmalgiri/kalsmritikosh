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
    @State private var selected: GraphNode?
    @State private var evidence: [String] = []
    @State private var events: [ChronologyEntry] = []
    @State private var tab = 0

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
    }

    private var graph: some View {
        HStack(alignment: .top) {
            GeometryReader { geo in
                ZStack {
                    Canvas { ctx, _ in
                        for e in edges {
                            guard let p = positions[e.a], let q = positions[e.b] else { continue }
                            var path = Path(); path.move(to: p); path.addLine(to: q)
                            ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: min(4, 0.5 + Double(e.count) * 0.3))
                        }
                    }
                    ForEach(nodes) { n in
                        if let p = positions[n.id] {
                            Text(n.name)
                                .font(.caption2).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(selected == n ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), in: Capsule())
                                .position(p)
                                .onTapGesture { Task { selected = n; evidence = await appState.evidenceDocuments(between: n.id, and: nil) } }
                                .accessibilityLabel("\(n.name), \(n.weight) links")
                        }
                    }
                }
                .onAppear { place(in: geo.size) }
                .onChange(of: nodes) { _, _ in place(in: geo.size) }
            }
            .frame(minWidth: 560, minHeight: 460)
            VStack(alignment: .leading, spacing: 6) {
                Text(selected?.name ?? "Select a name").font(.headline)
                if let s = selected {
                    let linked = edges.filter { $0.a == s.id || $0.b == s.id }
                    Text("\(linked.count) relationship\(linked.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    ForEach(linked.prefix(12)) { e in
                        let other = nodes.first { $0.id == (e.a == s.id ? e.b : e.a) }?.name ?? "?"
                        Button("\(e.kind): \(other) (\(e.count))") {
                            Task { evidence = await appState.evidenceDocuments(between: e.a, and: e.b) }
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
                Divider()
                Text("Evidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(evidence, id: \.self) { Text($0).font(.caption2) }
                Spacer()
            }
            .frame(width: 260)
        }
    }

    private var timeline: some View {
        Chart(events) { e in
            PointMark(x: .value("Date", e.date), y: .value("Kind", e.source))
                .annotation(position: .top, alignment: .leading) { Text(e.title).font(.system(size: 8)).lineLimit(1) }
        }
        .frame(minHeight: 460)
    }

    private func place(in size: CGSize) {
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
