//
//  CrossDocumentMatrixView.swift
//  Kalsmritikosh
//
//  Ask one question across EVERY document at once and see what each source says,
//  as a cited table of verbatim passages. Deterministic full-text match — no
//  model, nothing summarized-away. The cross-source review lawyers/journalists
//  reach for, done evidence-first.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct CrossDocumentMatrixView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var rows: [CrossDocMatrixRow] = []
    @State private var searching = false
    @State private var didRun = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if searching {
                ProgressView("Matching every document…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .padding(16)
        .navigationTitle("Cross-Document Matrix")
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem {
                    Menu {
                        Button {
                            exportMarkdown()
                        } label: {
                            Label("Markdown table", systemImage: "tablecells")
                        }
                        Button {
                            exportReceipt()
                        } label: {
                            Label("Verifiable receipt (.json)", systemImage: "checkmark.seal")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask across every document")
                .font(.title3.bold())
            Text("One question, one row per source — the best-matching passage from each document, verbatim and cited. No summarizing, no guessing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("e.g. termination clause, payment terms, non-disclosure…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { run() }
                if !query.isEmpty {
                    Button { query = ""; rows = []; didRun = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Button("Search all") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text(didRun ? "No document mentions that." : "Enter a topic to see what each document says.")
                .foregroundStyle(.secondary)
            Text(didRun
                 ? "Try a person, an amount, or a phrase that appears in the files — or add more files."
                 : "Ask one question across every document at once — e.g. a party name, a clause, a payment.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                SurfaceOpener.open(.sources)
            } label: { Label("Add your files", systemImage: "folder") }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(rows.count) source(s) mention “\(query)”")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            List(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(Theme.brand)
                        Text(row.filename).font(.subheadline.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                        if let page = row.pageNumber {
                            Text("p.\(page)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let date = row.date {
                            Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                        if row.url != nil {
                            Button {
                                openSource(row)
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                            .help("Open the source file")
                        }
                    }
                    Text(row.passage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private func run() {
        let q = query
        searching = true
        Task {
            let result = await appState.crossDocumentMatrix(query: q)
            await MainActor.run {
                self.rows = result
                self.searching = false
                self.didRun = true
            }
        }
    }

    private func openSource(_ row: CrossDocMatrixRow) {
        #if canImport(AppKit)
        guard let url = row.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func exportMarkdown() {
        #if canImport(AppKit)
        let md = CrossDocumentMatrix.markdown(query: query, rows: rows)
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        let safe = query.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = "matrix-\(safe.isEmpty ? "results" : safe).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try md.write(to: url, atomically: true, encoding: .utf8) }
        catch { print("Matrix export failed: \(error)") }
        #endif
    }

    /// Export a tamper-evident receipt: each source row becomes a claim pinned to
    /// its verbatim passage + SHA-256, linked in a hash chain anyone can re-check.
    private func exportReceipt() {
        #if canImport(AppKit)
        let capturedRows = rows
        let q = query
        Task {
            // Bind each entry to the source file's custody hash (court-grade).
            let ids = Set(capturedRows.map(\.objectID))
            let hashes = (try? await appState.objects?.sourceHashes(for: ids)) ?? [:]
            let drafts = capturedRows.map { r -> ReceiptDraft in
                var source = r.pageNumber.map { "\(r.filename) (p.\($0))" } ?? r.filename
                if let h = hashes[r.objectID] { source += " [sha256:\(h)]" }
                return ReceiptDraft(claim: "\"\(q)\" appears in \(r.filename)", source: source, date: r.date, passage: r.passage)
            }
            let sealed = VerifiableReceipt.seal(title: "Cross-document matrix: \(q)", drafts: drafts)
            let json = VerifiableReceipt.json(sealed)
            await MainActor.run {
                let panel = NSSavePanel()
                if let jsonType = UTType(filenameExtension: "json") { panel.allowedContentTypes = [jsonType] }
                let safe = q.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
                panel.nameFieldStringValue = "receipt-\(safe.isEmpty ? "results" : safe).json"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try json.write(to: url, atomically: true, encoding: .utf8) }
                catch { print("Receipt export failed: \(error)") }
            }
        }
        #endif
    }
}
