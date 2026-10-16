//
//  ContentView.swift
//  KalsmritikoshViewer
//
//  W4-6 — the read-only iPhone/iPad companion. Open a `.kalsnapshot` folder exported
//  from the Mac (Settings ▸ Backup ▸ Export signed snapshot…, copied over with Finder,
//  AirDrop or the Files app). It is checked first; only a verified snapshot opens. Then
//  browse documents, search passages, and open any passage's original file from the
//  snapshot. Nothing is synced and nothing goes online; the snapshot is never changed.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook

@MainActor
@Observable
final class ViewerModel {
    var ledger: SnapshotLedger?
    var verdict: SnapshotVerdict?
    var documents: [SnapshotDocument] = []
    var opening = false
    /// Set once the snapshot verifies: its ledger waits for the passphrase.
    var awaitingPassphrase = false
    var passphraseProblem: String?
    private var scoped: URL?
    private var verified: (folder: URL, entries: [SnapshotVerifier.Entry])?

    func open(_ folder: URL) async {
        close()
        opening = true
        defer { opening = false }
        let access = folder.startAccessingSecurityScopedResource()
        if access { scoped = folder }
        let (verdict, entries) = await Task.detached { SnapshotVerifier.verify(folder) }.value
        self.verdict = verdict
        guard verdict.isVerified else { return }
        verified = (folder, entries)
        awaitingPassphrase = true
    }

    func unlock(_ passphrase: String) async {
        guard let v = verified else { return }
        opening = true
        defer { opening = false }
        do {
            let l = try await Task.detached { try SnapshotLedger(folder: v.folder, entries: v.entries, passphrase: passphrase) }.value
            ledger = l
            awaitingPassphrase = false
            passphraseProblem = nil
            documents = await Task.detached { l.documents() }.value
        } catch {
            passphraseProblem = error.localizedDescription
            awaitingPassphrase = true
        }
    }

    func close() {
        ledger = nil; documents = []; verified = nil
        awaitingPassphrase = false; passphraseProblem = nil
        scoped?.stopAccessingSecurityScopedResource(); scoped = nil
    }
}

struct ContentView: View {
    @State private var model = ViewerModel()
    @State private var importing = false
    @State private var selection: SnapshotDocument?
    @State private var query = ""
    @State private var hits: [SnapshotPassage] = []
    @State private var focusPassage: String?
    @State private var passphrase = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Kalsmritikosh")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open Snapshot", systemImage: "folder") { importing = true }
                    }
                }
        } detail: {
            if let doc = selection, let ledger = model.ledger {
                DocumentView(document: doc, ledger: ledger, focus: focusPassage)
            } else {
                ContentUnavailableView("No document selected", systemImage: "doc.text",
                                       description: Text(model.ledger == nil ? "Open a signed snapshot exported from Kalsmritikosh on your Mac." : "Choose a document or search."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await model.open(url); selection = nil; hits = [] } }
        }
        .overlay { if model.opening { ProgressView("Checking the snapshot…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .alert("Snapshot passphrase", isPresented: Binding(get: { model.awaitingPassphrase }, set: { if !$0 { model.awaitingPassphrase = false } })) {
            SecureField("Passphrase", text: $passphrase)
            Button("Open") { let p = passphrase; passphrase = ""; Task { await model.unlock(p) } }
            Button("Cancel", role: .cancel) { passphrase = ""; model.close() }
        } message: {
            Text(model.passphraseProblem ?? "Enter the passphrase set when this snapshot was exported on the Mac.")
        }
    }

    @ViewBuilder private var sidebar: some View {
        List(selection: $selection) {
            if let v = model.verdict {
                Section {
                    Label(v.message, systemImage: v.isVerified ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(v.isVerified ? Color.green : Color.red)
                }
            }
            if model.ledger != nil {
                if !query.isEmpty {
                    Section("Passages matching “\(query)” (\(hits.count))") {
                        ForEach(hits) { p in
                            Button {
                                focusPassage = p.id
                                selection = model.documents.first { $0.id == p.documentID } ?? model.ledger?.document(id: p.documentID)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.documents.first { $0.id == p.documentID }?.title ?? "Document").font(.caption.bold())
                                    Text(p.text).font(.caption).lineLimit(3)
                                }
                            }
                        }
                    }
                } else {
                    Section("Documents (\(model.documents.count))") {
                        ForEach(model.documents) { d in
                            NavigationLink(value: d) {
                                HStack {
                                    Text(d.title).lineLimit(2)
                                    if d.privileged { Image(systemName: "lock.fill").foregroundStyle(.orange).accessibilityLabel("Privileged") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search passages")
        .onChange(of: query) { _, q in
            guard let ledger = model.ledger else { return }
            Task { hits = await Task.detached { ledger.search(q) }.value }
        }
    }
}

struct DocumentView: View {
    let document: SnapshotDocument
    let ledger: SnapshotLedger
    let focus: String?
    @State private var passages: [SnapshotPassage] = []
    @State private var preview: URL?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    LabeledContent("Type", value: document.sourceType)
                    if document.privileged { Label("Marked privileged on the Mac", systemImage: "lock.fill").foregroundStyle(.orange) }
                    if let url = ledger.originalURL(fileID: document.fileID) {
                        Button("Open original", systemImage: "doc.viewfinder") { preview = url }
                    } else {
                        Text("The original file is not in this snapshot (it was exported without originals).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Passages (\(passages.count))") {
                    ForEach(passages) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.page.map { "Passage \(p.ordinal + 1) · page \($0)" } ?? "Passage \(p.ordinal + 1)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(p.text).font(.callout).textSelection(.enabled)
                        }
                        .id(p.id)
                        .listRowBackground(p.id == focus ? Color.accentColor.opacity(0.12) : nil)
                    }
                }
            }
            .navigationTitle(document.title)
            .quickLookPreview($preview)
            .task(id: document.id) {
                let l = ledger, id = document.id
                passages = await Task.detached { l.passages(of: id) }.value
                if let focus { proxy.scrollTo(focus, anchor: .center) }
            }
        }
    }
}
