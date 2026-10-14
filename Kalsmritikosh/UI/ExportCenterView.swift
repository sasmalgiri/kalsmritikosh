//
//  ExportCenterView.swift
//  Kalsmritikosh
//
//  W2-6 — export the timeline, the entity list or a set of sources (from a
//  search or a tag) in any of eight formats, with a pre-flight count first and
//  a signed receipt written beside the file.
//

import SwiftUI
import AppKit
import os

nonisolated enum LedgerExportSubject: String, CaseIterable, Identifiable, Sendable {
    case timeline, entities, sources
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timeline: return "Timeline"
        case .entities: return "People, organisations and other entities"
        case .sources: return "Source documents (search or tag)"
        }
    }
}

extension AppState {
    func exportTable(_ subject: LedgerExportSubject, query: String, limit: Int = 50_000) async -> LedgerExportTable? {
        guard let database else { return nil }
        do {
            switch subject {
            case .timeline:
                let rows = try await database.query("""
                    SELECT e.date, e.kind, e.title, COALESCE(e.summary, ''), f.url, e.confidence
                    FROM events e JOIN knowledge_objects ko ON ko.id = e.source_object_id JOIN files f ON f.id = ko.file_id
                    ORDER BY e.date LIMIT ?;
                    """, [.integer(Int64(limit))])
                let iso = ISO8601DateFormatter()
                var t = LedgerExportTable(title: "Timeline", columns: ["Date", "Kind", "Event", "Summary", "Source", "Confidence"],
                                    rows: [], sources: [], passages: [])
                for r in rows {
                    let source = r.string(4).flatMap { URL(string: $0)?.lastPathComponent } ?? ""
                    let summary = r.string(3) ?? ""
                    t.rows.append([r.date(0).map { iso.string(from: $0) } ?? "", r.string(1) ?? "", r.string(2) ?? "",
                                   summary, source, String(format: "%.2f", r.double(5) ?? 0)])
                    t.sources.append(source); t.passages.append(summary.isEmpty ? (r.string(2) ?? "") : summary)
                }
                t.originals = Array(repeating: nil, count: t.rows.count)
                return t
            case .entities:
                let rows = try await database.query("""
                    SELECT e.kind, e.value, COUNT(m.id), COUNT(DISTINCT m.source_object_id),
                           (SELECT f.url FROM entity_mentions m2 JOIN knowledge_objects ko ON ko.id = m2.source_object_id
                              JOIN files f ON f.id = ko.file_id WHERE m2.entity_id = e.id LIMIT 1),
                           (SELECT m3.surface FROM entity_mentions m3 WHERE m3.entity_id = e.id LIMIT 1)
                    FROM entities e LEFT JOIN entity_mentions m ON m.entity_id = e.id
                    GROUP BY e.id ORDER BY COUNT(m.id) DESC LIMIT ?;
                    """, [.integer(Int64(limit))])
                var t = LedgerExportTable(title: "Entities", columns: ["Name", "Kind", "Mentions", "Documents", "Example source"],
                                    rows: [], sources: [], passages: [])
                for r in rows {
                    let source = r.string(4).flatMap { URL(string: $0)?.lastPathComponent } ?? ""
                    t.rows.append([r.string(1) ?? "", r.string(0) ?? "", String(r.int(2) ?? 0), String(r.int(3) ?? 0), source])
                    t.sources.append(source); t.passages.append(r.string(5) ?? (r.string(1) ?? ""))
                }
                t.originals = Array(repeating: nil, count: t.rows.count)
                return t
            case .sources:
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                var ids: [UUID]
                if trimmed.hasPrefix("#") {
                    ids = (try? await tagsRepository?.subjects(taggedWith: String(trimmed.dropFirst()), kind: .object)) ?? []
                } else {
                    ids = await documentsMatching(trimmed)
                }
                ids = Array(ids.prefix(limit))
                var t = LedgerExportTable(title: "Sources: \(trimmed)", columns: ["Document", "Type", "Modified", "Path", "Text"],
                                    rows: [], sources: [], passages: [])
                var originals: [URL?] = []
                let iso = ISO8601DateFormatter()
                for start in stride(from: 0, to: ids.count, by: 400) {
                    let slice = Array(ids[start..<min(start + 400, ids.count)])
                    let marks = slice.map { _ in "?" }.joined(separator: ",")
                    for r in try await database.query("""
                        SELECT f.url, ko.source_type, f.modified_at, ko.content FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                        WHERE ko.id IN (\(marks)) ORDER BY f.modified_at;
                        """, slice.map { .uuid($0) }) {
                        let url = r.string(0).flatMap(URL.init(string:))
                        let text = r.string(3) ?? ""
                        t.rows.append([url?.lastPathComponent ?? "", r.string(1) ?? "", r.date(2).map { iso.string(from: $0) } ?? "",
                                       url?.path ?? "", text])
                        t.sources.append(url?.lastPathComponent ?? ""); t.passages.append(String(text.prefix(2000)))
                        originals.append(url)
                    }
                }
                t.originals = originals
                return t
            }
        } catch {
            KalsmritikoshLog.app.error("Export table failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct ExportCenterView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var subject: LedgerExportSubject = .timeline
    @State private var format: LedgerExportFormat = .csv
    @State private var query = ""
    @State private var table: LedgerExportTable?
    @State private var preflight: LedgerExportPreflight?
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.title3.bold())
            Picker("What", selection: $subject) { ForEach(LedgerExportSubject.allCases) { Text($0.label).tag($0) } }
            if subject == .sources {
                TextField("Search (e.g. type:email org:acme) or #tag", text: $query)
            }
            Picker("Format", selection: $format) {
                ForEach(LedgerExportFormat.allCases.filter { $0 != .mbox || subject == .sources }) { Text($0.label).tag($0) }
            }
            HStack {
                Button("Check") { Task { await check() } }
                    .disabled(working || (subject == .sources && query.trimmingCharacters(in: .whitespaces).isEmpty))
                Button("Export…") { Task { await export() } }
                    .disabled(working || preflight == nil)
            }
            if let preflight { Text(preflight.summary).font(.callout) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("A signed receipt (.receipt.json) is written beside every export, one entry per row, so anyone can check the file was not changed.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
        .onChange(of: subject) { _, _ in preflight = nil; table = nil; if subject != .sources && format == .mbox { format = .csv } }
        .onChange(of: format) { _, _ in preflight = nil }
        .onChange(of: query) { _, _ in preflight = nil }
    }

    private func check() async {
        working = true; defer { working = false }
        status = nil
        table = await appState.exportTable(subject, query: query)
        guard let table else { status = "Could not read the ledger."; preflight = nil; return }
        preflight = LedgerExportRenderer.preflight(table, format: format)
    }

    private func export() async {
        guard let table else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table.title.replacingOccurrences(of: "/", with: "-")).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        let fmt = format
        let (data, missing) = await Task.detached { () -> (Data, [String]) in
            var missing: [String] = []
            let d = LedgerExportRenderer.render(table, format: fmt, missing: &missing)
            return (d, missing)
        }.value
        guard !data.isEmpty || table.rows.isEmpty else { status = "Nothing could be written in this format."; return }
        do {
            try data.write(to: url, options: .atomic)
            let sealed = VerifiableReceipt.seal(title: "Export: \(table.title) (\(fmt.label))", drafts: LedgerExportRenderer.receiptDrafts(table).filter { !Set(missing).contains($0.source) })
            try Data(ReceiptSigner.exportJSON(sealed).utf8).write(to: url.appendingPathExtension("receipt.json"), options: .atomic)
            status = "Exported \(table.rows.count - missing.count) of \(table.rows.count) rows to \(url.lastPathComponent), with a receipt."
                + (missing.isEmpty ? "" : " Not exported (no readable original email): \(missing.prefix(5).joined(separator: ", "))\(missing.count > 5 ? " and \(missing.count - 5) more" : "").")
        } catch {
            KalsmritikoshLog.app.error("Export failed: \(error.localizedDescription, privacy: .public)")
            status = "Export failed: \(error.localizedDescription)"
        }
    }
}
