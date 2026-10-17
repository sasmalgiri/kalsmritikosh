//
//  WatchlistView.swift
//  Kalsmritikosh
//
//  N-3 — paste or import a list of names, save it, and see where they appear in
//  the archive (including other spellings). Each match opens its documents.
//

import SwiftUI
import UniformTypeIdentifiers
import os

extension AppState {
    public var watchlists: WatchlistRepository? {
        guard ProductModuleFlags.isEnabled(.watchlists), let database else { return nil }
        return WatchlistRepository(database: database)
    }

    /// Match terms against people and organisations (with aliases) and count the documents each match appears in.
    public func matchWatchlist(_ terms: [String]) async -> [(match: WatchlistMatch, documents: [String])] {
        guard let database else { return [] }
        do {
            let rows = try await database.query("""
                SELECT e.id, e.value, GROUP_CONCAT(a.alias_normalized, '|')
                FROM entities e LEFT JOIN entity_aliases a ON a.entity_id = e.id
                WHERE e.merged_into IS NULL AND e.kind IN ('person','organization','vendor','client')
                GROUP BY e.id LIMIT 20000;
                """, [])
            let candidates = rows.compactMap { r -> WatchlistMatcher.Candidate? in
                guard let id = r.uuid(0), let name = r.string(1) else { return nil }
                return .init(entityID: id, name: name, aliases: (r.string(2) ?? "").split(separator: "|").map(String.init))
            }
            var out: [(WatchlistMatch, [String])] = []
            for m in WatchlistMatcher.match(terms: terms, candidates: candidates) {
                let docs = try await database.query("""
                    SELECT DISTINCT f.url FROM entity_mentions mn JOIN knowledge_objects ko ON ko.id = mn.source_object_id
                    JOIN files f ON f.id = ko.file_id WHERE mn.entity_id = ? LIMIT 20;
                    """, [.uuid(m.entityID)]).compactMap { $0.string(0) }.map { URL(string: $0)?.lastPathComponent ?? $0 }
                out.append((m, docs))
            }
            return out
        } catch {
            KalsmritikoshLog.app.error("Watchlist match failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

struct WatchlistView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [Watchlist] = []
    @State private var name = ""
    @State private var text = ""
    @State private var results: [(match: WatchlistMatch, documents: [String])] = []
    @State private var running = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watchlists").font(.title3.bold())
            Text("One name per line — people or companies. Matches include other spellings and word orders; each is a lead to check, not proof of identity.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("List name", text: $name).textFieldStyle(.roundedBorder)
                    TextEditor(text: $text).font(.callout.monospaced())
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Button("Import CSV/text…") { importing = true }
                        Button("Save list") { Task { await save() } }.disabled(name.isEmpty || terms.isEmpty)
                        Button(running ? "Matching…" : "Find in archive") { Task { await run(terms) } }
                            .buttonStyle(.borderedProminent).disabled(running || terms.isEmpty)
                    }
                    if !lists.isEmpty {
                        Text("Saved lists").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(lists) { l in
                            Button("\(l.name) (\(l.terms.count))") { name = l.name; text = l.terms.joined(separator: "\n"); Task { await run(l.terms) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minWidth: 260)
                List(results, id: \.match.id) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.match.term) → \(r.match.entityName)").font(.callout.weight(.semibold))
                        Text("\(label(r.match.strength)) · matched “\(r.match.matchedOn)”").font(.caption2).foregroundStyle(.secondary)
                        if !r.documents.isEmpty {
                            Text(r.documents.prefix(5).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(minWidth: 320, minHeight: 320)
            }
            HStack { Text("\(results.count) match\(results.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .task { lists = (try? await appState.watchlists?.all()) ?? [] }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                // First column of each line.
                text = s.split(whereSeparator: \.isNewline).map { $0.split(separator: ",").first.map(String.init) ?? "" }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }.filter { !$0.isEmpty }.joined(separator: "\n")
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
    }

    private var terms: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() async {
        _ = try? await appState.watchlists?.create(name: name, terms: terms)
        lists = (try? await appState.watchlists?.all()) ?? []
    }

    private func run(_ t: [String]) async {
        running = true
        results = await appState.matchWatchlist(t)
        running = false
    }

    private func label(_ s: WatchlistMatch.Strength) -> String {
        switch s {
        case .exact: return "Exact"
        case .reordered: return "Same words, other order"
        case .spelling: return "Similar spelling"
        case .initials: return "Initials match"
        }
    }
}
