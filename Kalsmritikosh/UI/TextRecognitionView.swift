//
//  TextRecognitionView.swift
//  Kalsmritikosh
//
//  W4-1 — scanned documents and photos whose recognised text is thin (fewer
//  than 80 characters per page-sized file), so weak OCR is visible instead of
//  silently passing as "read"; and a searchable-PDF copy of any of them.
//

import SwiftUI
import AppKit
import os

nonisolated struct ScanItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let url: URL
    let characters: Int
}

extension AppState {
    /// W4-1 — re-read every PDF whose structure came from an older parser version (once each).
    func rereadScannedPDFs(progress: @escaping @MainActor (Int, Int) -> Void) async -> (reprocessed: Int, upToDate: Int, failed: Int) {
        guard let database, let ingest else { return (0, 0, 0) }
        let ids = ((try? await database.query("SELECT id FROM source_versions WHERE detected_type = 'pdf';", [])) ?? []).compactMap { $0.uuid(0) }
        var done = 0, fresh = 0, failed = 0
        for (i, id) in ids.enumerated() {
            do {
                switch try await ingest.reprocess(sourceVersionID: id) {
                case .upToDate: fresh += 1
                case .changedOutputRejected: failed += 1
                default: done += 1
                }
            } catch {
                failed += 1
                KalsmritikoshLog.app.error("OCR re-read failed: \(error.localizedDescription, privacy: .public)")
            }
            progress(i + 1, ids.count)
        }
        return (done, fresh, failed)
    }

    func scannedItems(limit: Int = 3000) async -> [ScanItem] {
        guard let database else { return [] }
        return ((try? await database.query("""
            SELECT ko.id, f.url, LENGTH(ko.content) FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE LOWER(f.url) LIKE '%.pdf' OR LOWER(f.url) LIKE '%.jpg' OR LOWER(f.url) LIKE '%.jpeg'
               OR LOWER(f.url) LIKE '%.png' OR LOWER(f.url) LIKE '%.heic' OR LOWER(f.url) LIKE '%.tif' OR LOWER(f.url) LIKE '%.tiff'
            ORDER BY LENGTH(ko.content) ASC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []).compactMap { r in
            guard let id = r.uuid(0), let url = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return ScanItem(id: id, name: url.lastPathComponent, url: url, characters: Int(r.int(2) ?? 0))
        }
    }
}

struct TextRecognitionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ScanItem] = []
    @State private var selection: ScanItem.ID?
    @State private var status: String?
    @State private var working = false
    @State private var weakOnly = true

    private var shown: [ScanItem] { weakOnly ? items.filter { $0.characters < 80 } : items }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text recognition").font(.title3.bold())
            Text("Scanned PDFs and photos, fewest recognised characters first. Make a searchable PDF copy of any of them; the original is not changed.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Only files with little or no recognised text", isOn: $weakOnly)
            List(shown, selection: $selection) { i in
                HStack {
                    Text(i.name).font(.callout)
                    Spacer()
                    Text(i.characters == 0 ? "no text" : "\(i.characters) characters").font(.caption)
                        .foregroundStyle(i.characters < 80 ? .orange : .secondary)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button(working ? "Working…" : "Re-read scanned PDFs at 300 dpi") { Task { await reread() } }
                    .disabled(working)
                    .help("Re-reads each PDF once with the improved text recognition; a page's text is replaced only if the new reading is not worse.")
                Button(working ? "Working…" : "Save searchable PDF…") { Task { await makePDF() } }
                    .disabled(working || selection == nil)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(shown.count) shown").font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .task { items = await appState.scannedItems() }
    }

    private func reread() async {
        working = true; defer { working = false }
        let r = await appState.rereadScannedPDFs { done, total in status = "Re-reading \(done) of \(total)…" }
        status = "Re-read \(r.reprocessed) PDF(s); \(r.upToDate) already up to date; \(r.failed) kept their earlier reading."
        items = await appState.scannedItems()
    }

    private func makePDF() async {
        guard let item = items.first(where: { $0.id == selection }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (item.url.deletingPathExtension().lastPathComponent) + " (searchable).pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        working = true; defer { working = false }
        let src = item.url
        do {
            let r = try await Task.detached { () throws -> SearchablePDF.Result in
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                return try SearchablePDF.make(from: src, to: dest)
            }.value
            status = "Saved: \(r.pages) page(s), \(r.recognizedLines) lines recognised (mean confidence \(String(format: "%.2f", r.meanConfidence)))."
        } catch {
            KalsmritikoshLog.app.error("Searchable PDF failed: \(error.localizedDescription, privacy: .public)")
            status = "Failed: \(error.localizedDescription)"
        }
    }
}
