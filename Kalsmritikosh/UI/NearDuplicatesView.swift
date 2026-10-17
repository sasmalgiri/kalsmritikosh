//
//  NearDuplicatesView.swift
//  Kalsmritikosh
//
//  W2-4 — find drafts, forwards and re-saved copies (near-duplicates), link them
//  as versions of one another (nothing merged or deleted), and let the
//  corroboration meter count each group as ONE source.
//

import SwiftUI
import os

extension AppState {

    /// Compute and store near-duplicate groups over the most recent documents.
    @discardableResult
    func computeNearDuplicates(threshold: Double = 0.8, limit: Int = 3000) async -> [NearDuplicateGroup] {
        guard ProductModuleFlags.isEnabled(.nearDuplicates), let database else { return [] }
        let rows = (try? await database.query("""
            SELECT ko.id, (SELECT GROUP_CONCAT(text, ' ') FROM (SELECT text FROM chunks c WHERE c.object_id = ko.id
                AND c.review_status IS NULL AND c.superseded_by_run IS NULL ORDER BY ordinal LIMIT 20))
            FROM knowledge_objects ko ORDER BY ko.created_at DESC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        let docs = rows.compactMap { r in r.uuid(0).map { (id: $0, text: r.string(1) ?? "") } }
        let groups = await Task.detached { NearDuplicateFinder.find(documents: docs, threshold: threshold) }.value
        let now = Date()
        do {
            try await database.withSavepoint("near_dup_store") { db in
                // Replace derived links (a recomputation, not user data).
                try db.exec("DELETE FROM near_duplicate_members;", [])
                for g in groups {
                    guard let gid = g.members.first?.uuidString else { continue }
                    for m in g.members {
                        try db.exec("INSERT INTO near_duplicate_members (object_id, group_id, similarity, computed_at) VALUES (?, ?, ?, ?);",
                                    [.uuid(m), .text(gid), .real(g.weakestSimilarity), .date(now)])
                    }
                }
            }
        } catch {
            KalsmritikoshLog.app.error("Near-duplicate store failed: \(error.localizedDescription, privacy: .public)")
        }
        return groups
    }

    /// Group keys for the corroboration meter: "nd:<group>" for objects in a near-duplicate group.
    func nearDuplicateKeys(for ids: Set<UUID>) async -> [UUID: String] {
        guard ProductModuleFlags.isEnabled(.nearDuplicates), let database, !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? await database.query(
            "SELECT object_id, group_id FROM near_duplicate_members WHERE object_id IN (\(marks));",
            ids.map { .uuid($0) })) ?? []
        var out: [UUID: String] = [:]
        for r in rows { if let id = r.uuid(0), let g = r.string(1) { out[id] = "nd:" + g } }
        return out
    }
}

struct NearDuplicatesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [NearDuplicateGroup] = []
    @State private var names: [UUID: String] = [:]
    @State private var running = false
    @State private var threshold = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Near-duplicates").font(.title3.bold())
            Text("Drafts, forwards and re-saved copies, linked as versions of one another. Nothing is merged or deleted; the corroboration meter counts each group as one source.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Similarity at least \(Int(threshold * 100))%").font(.caption)
                Slider(value: $threshold, in: 0.5...0.98).frame(width: 200)
                Button(running ? "Comparing…" : "Find near-duplicates") {
                    Task {
                        running = true
                        groups = await appState.computeNearDuplicates(threshold: threshold)
                        names = (try? await appState.objects?.sourceFilenames(for: Set(groups.flatMap(\.members)))) ?? [:]
                        running = false
                    }
                }
                .disabled(running)
            }
            List(Array(groups.enumerated()), id: \.offset) { _, g in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(g.members.count) versions · at least \(Int(g.weakestSimilarity * 100))% alike").font(.caption.weight(.semibold))
                    ForEach(g.members, id: \.self) { Text("• \(names[$0] ?? $0.uuidString.prefix(8).description)").font(.caption2) }
                }
            }
            .frame(minHeight: 300)
            HStack { Text("\(groups.count) group\(groups.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }
}
