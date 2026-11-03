//
//  WatchlistView.swift
//  Kalsmritikosh
//
//  N-3 / N2 — paste or import a list of names, phone numbers and email addresses, save it, and
//  screen it against the whole archive or one case: per term, the documents and mentions found
//  (as a named entity, including other spellings, or as words in the text), the terms with no
//  match, a passage per document that opens its source, and a CSV export of the screening.
//

import SwiftUI
import UniformTypeIdentifiers
import os

extension AppState {
    public var watchlists: WatchlistRepository? {
        guard ProductModuleFlags.isEnabled(.watchlists), let database else { return nil }
        return WatchlistRepository(database: database)
    }

    /// N2 — screen `lines` in the whole archive (`caseChoice` nil) or one case's in-scope sources.
    /// The case's scope comes from the case scope resolver (fails closed: an unreadable case
    /// screens nothing); sensitive and privileged documents go through the screen gate as in Search.
    public func screenNames(_ lines: [String], caseChoice: StudioCaseChoice?) async -> Result<ScreeningReport, Error> {
        guard let database, let chunks, let evidenceStore else {
            return .failure(ScreeningUnavailable())
        }
        do {
            var scope = RetrievalSourceScope.unscoped
            var label = "Whole archive"
            if let caseChoice {
                label = "Case “\(caseChoice.title)”"
                if let cases = investigationCases, let record = try await cases.fetch(caseID: caseChoice.id) {
                    scope = try await CaseRetrievalScopeResolver(evidence: evidenceStore).scope(for: record)
                } else {
                    scope = .authorizing([])
                }
            }
            let authorizer = screenAuthorizer
            let report = try await BatchScreening(database: database, chunks: chunks, evidence: evidenceStore)
                .run(lines: lines, scope: scope, scopeLabel: label,
                     visible: { ids in await authorizer?.filterObjectIDs(ids, boundary: .globalOwner) ?? [] })
            return .success(report)
        } catch {
            KalsmritikoshLog.app.error("Name screening failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }
}

struct ScreeningUnavailable: LocalizedError {
    var errorDescription: String? { "The ledger isn't ready yet; nothing was screened." }
}

/// A CSV or text file being imported: its rows, the chosen column and whether row 1 is a header.
private struct ScreeningImport: Identifiable {
    let id = UUID()
    let fileName: String
    let rows: [[String]]
}

struct WatchlistView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [Watchlist] = []
    @State private var name = ""
    @State private var text = ""
    @State private var report: ScreeningReport?
    @State private var problem: String?
    @State private var status: String?
    @State private var running = false
    @State private var importing = false
    @State private var pendingImport: ScreeningImport?
    @State private var cases: [StudioCaseChoice] = []
    @State private var caseID: UUID?
    @State private var openSource: CitationOpenTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watchlists").font(.title3.bold())
            Text("One term per line — a name, a phone number or an email address. Each term is looked for as a named person or organisation (including other spellings and word orders) and as words in the text. Each hit is a lead to check, not proof of identity.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                editor.frame(minWidth: 280)
                results.frame(minWidth: 380, minHeight: 320)
            }
            HStack {
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 520)
        .task {
            lists = (try? await appState.watchlists?.all()) ?? []
            cases = await appState.studioCaseChoices()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let s = try String(contentsOf: url, encoding: .utf8)
                pendingImport = ScreeningImport(fileName: url.deletingPathExtension().lastPathComponent, rows: ScreeningListImport.rows(s))
            } catch {
                KalsmritikoshLog.ui.error("Watchlist import unreadable: \(error.localizedDescription, privacy: .public)")
                problem = "The file could not be read as UTF-8 text: \(error.localizedDescription)"
            }
        }
        .sheet(item: $pendingImport) { imp in
            ScreeningImportSheet(imp: imp) { values in
                pendingImport = nil
                guard let values else { return }
                text = values.joined(separator: "\n")
                if name.isEmpty { name = imp.fileName }
            }
        }
        .sheet(item: $openSource) { target in
            CitationSourceSheet(target: target) { openSource = nil }
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("List name", text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.callout.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Import CSV/text…") { importing = true }
                Button("Save list") { Task { await save() } }.disabled(name.isEmpty || lines.isEmpty)
            }
            Picker("Screen in", selection: $caseID) {
                Text("Whole archive").tag(UUID?.none)
                ForEach(cases) { Text("Case: \($0.title)").tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("watchlist.scope")
            Button(running ? "Screening…" : "Screen list") { Task { await run(lines) } }
                .buttonStyle(.borderedProminent).disabled(running || lines.isEmpty)
                .accessibilityIdentifier("watchlist.screen")
            if !lists.isEmpty {
                Text("Saved lists").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lists) { l in
                    Button("\(l.name) (\(l.terms.count))") { name = l.name; text = l.terms.joined(separator: "\n"); Task { await run(l.terms) } }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let report {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(report.scopeLabel) · \(report.documentsSearched) document\(report.documentsSearched == 1 ? "" : "s") searched · \(report.results.filter { !$0.documents.isEmpty }.count) of \(report.results.count) term\(report.results.count == 1 ? "" : "s") found")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export CSV…") { export(report) }
                        .accessibilityIdentifier("watchlist.export")
                }
                List {
                    ForEach(report.results) { r in
                        Section {
                            if r.documents.isEmpty {
                                Text(report.noMatchText(r)).font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(r.documents) { d in
                                    Button { open(d) } label: { row(d) }.buttonStyle(.plain)
                                        .help("Open the source at this passage")
                                }
                                if r.withheldDocuments > 0 {
                                    Text("\(r.withheldDocuments) more document\(r.withheldDocuments == 1 ? " is" : "s are") marked sensitive or privileged and not shown.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if r.passageLimitReached {
                                    Text("The text search stopped at its passage limit; there may be more documents.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        } header: {
                            HStack {
                                Text(r.term.raw).font(.callout.weight(.semibold))
                                Text(r.term.kind.label).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(r.documents.count) document\(r.documents.count == 1 ? "" : "s") · \(r.mentions) mention\(r.mentions == 1 ? "" : "s")")
                                    .font(.caption.monospacedDigit()).foregroundStyle(r.documents.isEmpty ? .tertiary : .secondary)
                            }
                        }
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Screen a list to see, for every term, where it appears — and which terms have no match.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ d: ScreeningDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(d.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(d.mentions)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(d.howFound).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if !d.passage.isEmpty {
                Text(d.passage).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() async {
        do {
            _ = try await appState.watchlists?.create(name: name, terms: lines)
            lists = (try await appState.watchlists?.all()) ?? []
            status = "Saved “\(name)”."
        } catch {
            KalsmritikoshLog.ui.error("Watchlist save failed: \(error.localizedDescription, privacy: .public)")
            problem = "The list could not be saved: \(error.localizedDescription)"
        }
    }

    private func run(_ t: [String]) async {
        running = true
        problem = nil
        status = nil
        switch await appState.screenNames(t, caseChoice: cases.first { $0.id == caseID }) {
        case .success(let r): report = r
        case .failure(let e): problem = "Screening failed: \(e.localizedDescription)"
        }
        running = false
    }

    private func open(_ d: ScreeningDocument) {
        Task { @MainActor in
            do {
                guard let repo = appState.objects, let url = try await repo.fetchSourceURL(id: d.objectID) else {
                    problem = "The source of “\(d.name)” could not be found."
                    return
                }
                openSource = CitationOpenTarget(url: url, objectID: d.objectID, quote: d.highlight)
            } catch {
                KalsmritikoshLog.ui.error("Watchlist open source failed: \(error.localizedDescription, privacy: .public)")
                problem = "The source could not be opened: \(error.localizedDescription)"
            }
        }
    }

    private func export(_ report: ScreeningReport) {
        #if canImport(AppKit)
        let text: String
        switch ProtectedExport.prepare(report.csv()) {
        case .success(let safe): text = safe
        case .failure(let refusal): refusal.present(); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\((name.isEmpty ? "Name screening" : name).replacingOccurrences(of: "/", with: "-")).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            status = "Exported the screening of \(report.results.count) term\(report.results.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            KalsmritikoshLog.ui.error("Watchlist export failed: \(error.localizedDescription, privacy: .public)")
            problem = "Export failed: \(error.localizedDescription)"
        }
        #endif
    }
}

/// Choose which column of an imported file holds the terms, and whether its first row is a header.
private struct ScreeningImportSheet: View {
    let imp: ScreeningImport
    let onDone: ([String]?) -> Void
    @State private var hasHeader = false
    @State private var column = 0

    var body: some View {
        let titles = ScreeningListImport.columnTitles(imp.rows, hasHeader: hasHeader)
        let values = ScreeningListImport.values(imp.rows, column: column, hasHeader: hasHeader)
        VStack(alignment: .leading, spacing: 10) {
            Text("Import “\(imp.fileName)”").font(.headline)
            Toggle("First row is a header", isOn: $hasHeader)
                .accessibilityIdentifier("watchlist.import.header")
            if titles.count > 1 {
                Picker("Column", selection: $column) {
                    ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
                }
                .accessibilityIdentifier("watchlist.import.column")
            }
            Text("\(values.count) term\(values.count == 1 ? "" : "s")\(values.isEmpty ? "" : ", starting:")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(values.prefix(5).enumerated()), id: \.offset) { Text($0.element).font(.callout.monospaced()).lineLimit(1) }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Use these terms") { onDone(values) }
                    .buttonStyle(.borderedProminent).disabled(values.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}
