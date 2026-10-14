//
//  ImageIntelligenceView.swift
//  Kalsmritikosh
//
//  N-7 — on-device image intelligence (Vision):
//    • Similar images: a feature print per photo; photos whose prints are closer
//      than the threshold are grouped (copies, resizes, crops). "Where else does
//      this photo appear" ranks every photo by distance to one.
//    • Faces: OFF until the user turns it on here. Faces are detected and grouped
//      by appearance; groups are unnamed until the user names one, and a name is
//      stored only as the user's own tag ("Face: <name>") on those documents. The
//      app never claims who anyone is.
//  Prints are computed when asked and kept only for this window; nothing leaves the Mac.
//

import SwiftUI
import Vision
import os

nonisolated struct ImageItem: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let url: URL
}

nonisolated struct FaceSample: Sendable {
    let objectID: UUID
    let name: String
    let print: FeaturePrintObservation
}

nonisolated enum ImageIntelligence {
    static func featurePrint(_ url: URL, region: NormalizedRect? = nil) async -> FeaturePrintObservation? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var request = GenerateImageFeaturePrintRequest()
        if let region { request.regionOfInterest = region }
        return try? await request.perform(on: url)
    }

    static func faces(_ url: URL) async -> [NormalizedRect] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return ((try? await DetectFaceRectanglesRequest().perform(on: url)) ?? []).map(\.boundingBox)
    }

    /// Groups indices whose pairwise distance is below `threshold` (union–find over all pairs).
    static func group(count: Int, threshold: Double, distance: (Int, Int) -> Double?) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
        for i in 0..<count { for j in (i + 1)..<max(i + 1, count) {
            if let d = distance(i, j), d < threshold { let a = root(i), b = root(j); if a != b { parent[max(a, b)] = min(a, b) } }
        }}
        var groups: [Int: [Int]] = [:]
        for i in 0..<count { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }
}

extension AppState {
    func imageItems(limit: Int = 2000) async -> [ImageItem] {
        guard let database else { return [] }
        return ((try? await database.query("""
            SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE LOWER(f.url) LIKE '%.jpg' OR LOWER(f.url) LIKE '%.jpeg' OR LOWER(f.url) LIKE '%.heic'
               OR LOWER(f.url) LIKE '%.png' OR LOWER(f.url) LIKE '%.tif' OR LOWER(f.url) LIKE '%.tiff'
            LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []).compactMap { r in
            guard let id = r.uuid(0), let url = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return ImageItem(id: id, name: url.lastPathComponent, url: url)
        }
    }
}

struct ImageIntelligenceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kalsmritikosh.faces.enabled") private var facesEnabled = false

    @State private var items: [ImageItem] = []
    @State private var prints: [UUID: FeaturePrintObservation] = [:]
    @State private var threshold = 0.45
    @State private var groups: [[ImageItem]] = []
    @State private var probe: UUID?
    @State private var ranked: [(ImageItem, Double)] = []
    @State private var faceGroups: [[FaceSample]] = []
    @State private var faceNames: [Int: String] = [:]
    @State private var progress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Similar images and faces").font(.title3.bold())
            Text("Computed on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            TabView {
                similarTab.tabItem { Text("Similar images") }
                facesTab.tabItem { Text("Faces") }
            }
            HStack {
                if let progress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .task { items = await appState.imageItems() }
    }

    private var similarTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Closeness").font(.caption)
                Slider(value: $threshold, in: 0.1...0.9).frame(width: 180)
                Button("Group similar photos (\(items.count))") { Task { await computeGroups() } }.disabled(progress != nil || items.isEmpty)
            }
            HSplitView {
                List(Array(groups.enumerated()), id: \.offset) { _, g in
                    VStack(alignment: .leading) {
                        Text("\(g.count) similar").font(.caption.weight(.semibold))
                        ForEach(g) { Text("• \($0.name)").font(.caption2) }
                    }
                }
                .frame(minWidth: 300)
                VStack(alignment: .leading) {
                    Picker("Where else does this appear?", selection: $probe) {
                        Text("Choose a photo").tag(UUID?.none)
                        ForEach(items) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .onChange(of: probe) { _, _ in Task { await rank() } }
                    List(ranked, id: \.0.id) { item, d in
                        HStack { Text(item.name).font(.caption); Spacer(); Text(String(format: "%.2f", d)).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }
                }
                .frame(minWidth: 300)
            }
        }
        .padding(6)
    }

    private var facesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Group faces by appearance", isOn: $facesEnabled)
            Text("Off by default. Groups are unnamed until you name one; a name is saved only as your own tag on those documents. The app never says who a person is.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if facesEnabled {
                Button("Find and group faces") { Task { await computeFaces() } }.disabled(progress != nil || items.isEmpty)
                List(Array(faceGroups.enumerated()), id: \.offset) { i, g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Group \(i + 1) · \(g.count) faces").font(.caption.weight(.semibold))
                            TextField("Name this group (optional)", text: Binding(get: { faceNames[i] ?? "" }, set: { faceNames[i] = $0 }))
                                .frame(width: 200)
                            Button("Save name as tag") { Task { await nameGroup(i) } }
                                .disabled((faceNames[i] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || appState.tagsRepository == nil)
                        }
                        Text(Set(g.map(\.name)).sorted().joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if appState.tagsRepository == nil {
                    Text("Naming needs Tags switched on (Settings → Modules).").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(6)
    }

    private func ensurePrints() async {
        var done = 0
        for item in items where prints[item.id] == nil {
            if let p = await ImageIntelligence.featurePrint(item.url) { prints[item.id] = p }
            done += 1
            if done % 20 == 0 { progress = "Reading photos… \(done)/\(items.count)" }
        }
    }

    private func computeGroups() async {
        progress = "Reading photos…"
        await ensurePrints()
        let pairs = items.compactMap { item in prints[item.id].map { (item, $0) } }
        let usable = pairs.map(\.0)
        let ps = pairs.map(\.1)
        let idx = ImageIntelligence.group(count: usable.count, threshold: threshold) { i, j in try? ps[i].distance(to: ps[j]) }
        groups = idx.map { $0.map { usable[$0] } }
        progress = nil
    }

    private func rank() async {
        guard let probe, let item = items.first(where: { $0.id == probe }) else { ranked = []; return }
        progress = "Comparing…"
        await ensurePrints()
        guard let p = prints[item.id] else { ranked = []; progress = "This photo could not be read."; return }
        ranked = items.filter { $0.id != probe }.compactMap { other in
            guard let q = prints[other.id], let d = try? p.distance(to: q) else { return nil }
            return (other, d)
        }.sorted { $0.1 < $1.1 }.prefix(50).map { $0 }
        progress = nil
    }

    private func computeFaces() async {
        guard facesEnabled else { return }
        var samples: [FaceSample] = []
        for (n, item) in items.enumerated() {
            for box in await ImageIntelligence.faces(item.url) {
                if let p = await ImageIntelligence.featurePrint(item.url, region: box) {
                    samples.append(FaceSample(objectID: item.id, name: item.name, print: p))
                }
            }
            if n % 10 == 0 { progress = "Looking for faces… \(n)/\(items.count)" }
        }
        let idx = ImageIntelligence.group(count: samples.count, threshold: 0.6) { i, j in try? samples[i].print.distance(to: samples[j].print) }
        faceGroups = idx.map { $0.map { samples[$0] } }
        faceNames = [:]
        progress = samples.isEmpty ? "No faces found." : nil
    }

    private func nameGroup(_ i: Int) async {
        guard let tags = appState.tagsRepository, faceGroups.indices.contains(i),
              let name = faceNames[i]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        do {
            let tag = try await tags.tag(named: "Face: \(name)")
            for id in Set(faceGroups[i].map(\.objectID)) { try await tags.attach(tagID: tag, to: .object, id) }
            progress = "Tagged \(Set(faceGroups[i].map(\.objectID)).count) document(s) “Face: \(name)”."
        } catch {
            KalsmritikoshLog.app.error("Face tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
