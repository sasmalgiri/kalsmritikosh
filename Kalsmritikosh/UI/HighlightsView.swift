//
//  HighlightsView.swift
//  Kalsmritikosh
//
//  W2-1 — highlights and notes. `AnnotationBar` sits above a source opened from
//  a citation: highlight the quoted passage (or text you paste from it), add a
//  note, and say whether you confirm or correct it. `HighlightsView` (Tools)
//  lists every highlight and exports them as Markdown, with or without notes.
//  The source file and the ledger's evidence are never edited.
//

import SwiftUI
import UniformTypeIdentifiers
import os

struct AnnotationBar: View {
    @Environment(AppState.self) private var appState
    let objectID: UUID
    let sourceURL: URL
    let suggestedQuote: String?

    @State private var existing: [Annotation] = []
    @State private var quote = ""
    @State private var note = ""
    @State private var stance: AnnotationStance = .note
    @State private var color = "yellow"
    @State private var message: String?

    static let colors = ["yellow", "green", "blue", "pink"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Passage to highlight (exact text from the source)", text: $quote)
                Picker("", selection: $color) {
                    ForEach(Self.colors, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(width: 100)
            }
            HStack {
                TextField("Your note (optional)", text: $note)
                Picker("", selection: $stance) {
                    ForEach(AnnotationStance.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 150)
                Button("Highlight") { Task { await save() } }
                    .disabled(quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            ForEach(existing) { a in
                HStack(alignment: .top) {
                    Rectangle().fill(Self.swatch(a.color)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(a.quote)”").font(.caption).lineLimit(2)
                        if let n = a.note { Text("\(a.stance == .note ? "" : a.stance.label + ": ")\(n)").font(.caption2).foregroundStyle(.secondary) }
                        else if a.stance != .note { Text(a.stance.label).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Remove") { Task { await remove(a) } }.buttonStyle(.borderless).font(.caption2)
                }
            }
        }
        .padding(10)
        .task {
            quote = suggestedQuote ?? ""
            await reload()
        }
    }

    static func swatch(_ name: String) -> Color {
        switch name { case "green": return .green; case "blue": return .blue; case "pink": return .pink; default: return .yellow }
    }

    private var repo: AnnotationsRepository? { appState.database.map { AnnotationsRepository(database: $0) } }

    private func reload() async {
        guard let repo, let db = appState.database else { return }
        let text = (try? await db.query("SELECT content FROM knowledge_objects WHERE id = ?;", [.uuid(objectID)]))?.first?.string(0)
        existing = (try? await repo.forDocument(objectID: objectID, sourceURL: sourceURL.absoluteString, currentText: text)) ?? []
    }

    private func save() async {
        guard let repo else { return }
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repo.add(objectID: objectID, sourceURL: sourceURL.absoluteString, quote: q,
                               note: note, color: color, stance: stance)
            note = ""; stance = .note
            message = "Saved beside the source; the source itself is unchanged."
            await reload()
        } catch {
            KalsmritikoshLog.app.error("Annotation save failed: \(error.localizedDescription, privacy: .public)")
            message = "Could not save the highlight."
        }
    }

    private func remove(_ a: Annotation) async {
        guard let repo else { return }
        do { try await repo.remove(a.id); await reload() }
        catch { KalsmritikoshLog.app.error("Annotation remove failed: \(error.localizedDescription, privacy: .public)") }
    }
}

nonisolated enum HighlightsExport {
    /// Markdown of highlights grouped by source; notes are included only when asked.
    static func markdown(_ items: [Annotation], names: [UUID: String], includeNotes: Bool) -> String {
        var out = "# Highlights\n\n"
        let grouped = Dictionary(grouping: items, by: \.objectID)
        for (object, list) in grouped.sorted(by: { (names[$0.key] ?? "") < (names[$1.key] ?? "") }) {
            out += "## \(names[object] ?? object.uuidString)\n\n"
            for a in list.sorted(by: { $0.createdAt < $1.createdAt }) {
                out += "> \(a.quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                if includeNotes {
                    if a.stance != .note { out += "*\(a.stance.label)*" + (a.note == nil ? "\n\n" : " — ") }
                    if let n = a.note { out += "\(n)\n\n" }
                }
            }
        }
        return out
    }
}

struct HighlightsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Annotation] = []
    @State private var names: [UUID: String] = [:]
    @State private var includeNotes = true
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlights and notes").font(.title3.bold())
            Text("Kept beside your sources, never written into them. Open a citation to add one.")
                .font(.caption).foregroundStyle(.secondary)
            List(items) { a in
                HStack(alignment: .top) {
                    Rectangle().fill(AnnotationBar.swatch(a.color)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[a.objectID] ?? "Document").font(.caption.weight(.semibold))
                        Text("“\(a.quote)”").font(.caption)
                        if a.stance != .note || a.note != nil {
                            Text([a.stance == .note ? nil : a.stance.label, a.note].compactMap { $0 }.joined(separator: " — "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") {
                        Task {
                            guard let db = appState.database else { return }
                            try? await AnnotationsRepository(database: db).remove(a.id)
                            await load()
                        }
                    }
                    .buttonStyle(.borderless).font(.caption2)
                }
            }
            .frame(minHeight: 300)
            HStack {
                Toggle("Include notes in export", isOn: $includeNotes)
                Button("Export Markdown…") { exporting = true }.disabled(items.isEmpty)
                Spacer()
                Text("\(items.count) highlight\(items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .task { await load() }
        .fileExporter(isPresented: $exporting,
                      document: RCAMarkdownDocument(text: HighlightsExport.markdown(items, names: names, includeNotes: includeNotes)),
                      contentType: .plainText, defaultFilename: "Highlights.md") { result in
            if case .failure(let error) = result {
                KalsmritikoshLog.app.error("Highlights export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func load() async {
        guard let db = appState.database else { return }
        items = (try? await AnnotationsRepository(database: db).all()) ?? []
        names = (try? await appState.objects?.sourceFilenames(for: Set(items.map(\.objectID)))) ?? [:]
    }
}
