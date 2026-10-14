//
//  NotesImportView.swift
//  Kalsmritikosh
//
//  N-9 — after a notes folder has been added in Sources (so its notes are in the
//  ledger), read its notes-app structure: Obsidian wiki-links and Notion page
//  links become note links (v146 `note_links`, with backlinks), tags become the
//  user's tags, Apple Notes exports are tagged by origin. Unresolved links are
//  counted and kept with their target text, never dropped.
//

import SwiftUI
import AppKit
import os

nonisolated struct NotesLinkReport: Sendable {
    let app: NotesApp
    let notes: Int
    let links: Int
    let unresolved: Int
    let tags: Int
}

extension AppState {
    /// Link every ingested note under `root`. Returns nil when no notes are found there.
    func linkNotes(under root: URL, as forced: NotesApp?) async -> NotesLinkReport? {
        guard let database else { return nil }
        let rows = (try? await database.query("""
            SELECT ko.id, f.url, ko.content FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE f.url LIKE ? AND (LOWER(f.url) LIKE '%.md' OR LOWER(f.url) LIKE '%.markdown' OR LOWER(f.url) LIKE '%.txt' OR LOWER(f.url) LIKE '%.html');
            """, [.text(root.absoluteString + "%")])) ?? []
        let notes = rows.compactMap { r -> (id: UUID, url: URL, text: String)? in
            guard let id = r.uuid(0), let url = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return (id, url, r.string(2) ?? "")
        }
        guard !notes.isEmpty else { return nil }
        let hasObsidian = FileManager.default.fileExists(atPath: root.appendingPathComponent(".obsidian").path)
        let app = forced ?? NotesFormat.detect(fileNames: notes.map { $0.url.lastPathComponent }, hasObsidianFolder: hasObsidian,
                                               sampleText: notes.prefix(50).map(\.text).joined(separator: "\n"))
        var byKey: [String: UUID] = [:]
        for n in notes { byKey[NotesFormat.key(n.url.deletingPathExtension().lastPathComponent)] = n.id }

        var links: [(from: UUID, to: UUID?, target: String)] = []
        for n in notes {
            let targets: [String]
            switch app {
            case .obsidian: targets = NotesFormat.wikiLinks(n.text)
            case .notion: targets = NotesFormat.markdownFileLinks(n.text)
            case .appleNotes: targets = []
            }
            for t in targets {
                let stem = (t as NSString).lastPathComponent
                links.append((n.id, byKey[NotesFormat.key(stem)], t))
            }
        }
        let kind = app == .obsidian ? "wikilink" : "notion_link"
        let now = Date()
        let ids = notes.map(\.id)
        do {
            try await database.withSavepoint("note_links") { db in
                // Re-run: retire this folder's previous links, then record the current ones.
                for start in stride(from: 0, to: ids.count, by: 400) {
                    let slice = Array(ids[start..<min(start + 400, ids.count)])
                    try db.exec("UPDATE note_links SET removed_at = ? WHERE removed_at IS NULL AND from_object_id IN (\(slice.map { _ in "?" }.joined(separator: ",")));",
                                [.date(now)] + slice.map { .uuid($0) })
                }
                for l in links {
                    try db.exec("INSERT INTO note_links (id, from_object_id, to_object_id, target, kind, created_at) VALUES (?, ?, ?, ?, ?, ?);",
                                [.uuid(UUID()), .uuid(l.from), l.to.map { .uuid($0) } ?? .null, .text(l.target), .text(kind), .date(now)])
                }
            }
        } catch {
            KalsmritikoshLog.app.error("Note links failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var tagCount = 0
        if let tags = tagsRepository {
            for n in notes {
                var names = app == .appleNotes ? ["Apple Notes"] : NotesFormat.tags(n.text)
                if app == .notion { names.append("Notion") }
                for name in names {
                    if let t = try? await tags.tag(named: name) { try? await tags.attach(tagID: t, to: .object, n.id); tagCount += 1 }
                }
            }
        }
        return NotesLinkReport(app: app, notes: notes.count, links: links.count,
                               unresolved: links.filter { $0.to == nil }.count, tags: tagCount)
    }

    /// Outgoing and incoming links of a note.
    func noteLinks(of id: UUID) async -> (out: [String], back: [String]) {
        guard let database else { return ([], []) }
        let out = ((try? await database.query("SELECT target, to_object_id FROM note_links WHERE removed_at IS NULL AND from_object_id = ?;", [.uuid(id)])) ?? [])
            .map { ($0.string(0) ?? "") + ($0.uuid(1) == nil ? " (not found)" : "") }
        let back = ((try? await database.query("""
            SELECT f.url FROM note_links l JOIN knowledge_objects ko ON ko.id = l.from_object_id JOIN files f ON f.id = ko.file_id
            WHERE l.removed_at IS NULL AND l.to_object_id = ?;
            """, [.uuid(id)])) ?? []).compactMap { $0.string(0).flatMap { URL(string: $0)?.lastPathComponent } }
        return (out, back)
    }
}

struct NotesImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var forced: NotesApp?
    @State private var report: NotesLinkReport?
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes apps").font(.title3.bold())
            Text("First add the folder in Sources (an Obsidian vault, an unzipped Notion export, or notes exported from Apple Notes). Then choose it here: links between notes become links you can follow both ways, and tags become your tags.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Folder type", selection: $forced) {
                Text("Detect automatically").tag(NotesApp?.none)
                ForEach(NotesApp.allCases, id: \.self) { Text($0.label).tag(NotesApp?.some($0)) }
            }
            .frame(width: 320)
            Button(working ? "Reading…" : "Choose notes folder…") { Task { await run() } }.disabled(working)
            if let r = report {
                Text("\(r.app.label): \(r.notes) notes, \(r.links) links (\(r.unresolved) point to notes that are not in the folder and are kept as text), \(r.tags) tags applied.")
                    .font(.callout)
                if appState.tagsRepository == nil { Text("Tags were not applied: Tags is switched off in Settings → Modules.").font(.caption).foregroundStyle(.orange) }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.orange) }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 320)
    }

    private func run() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        status = nil
        report = await appState.linkNotes(under: url, as: forced)
        if report == nil { status = "No notes from this folder are in the ledger yet. Add it in Sources first, then try again." }
    }
}

/// N-9 — a note's links and backlinks, shown above a source opened from a citation.
struct NoteLinksStrip: View {
    @Environment(AppState.self) private var appState
    let objectID: UUID
    @State private var links: (out: [String], back: [String]) = ([], [])

    var body: some View {
        Group {
            if !links.out.isEmpty || !links.back.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !links.out.isEmpty { Text("Links to: " + links.out.joined(separator: " · ")).font(.caption2).lineLimit(2) }
                    if !links.back.isEmpty { Text("Linked from: " + links.back.joined(separator: " · ")).font(.caption2).lineLimit(2) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .task { links = await appState.noteLinks(of: objectID) }
    }
}
