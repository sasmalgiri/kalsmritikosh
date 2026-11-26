//
//  ReferenceShelfView.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-17 (owner 2026-11-22) — not tested yet. The reference shelf: folders of reference
//  documents (acts, rules, manuals) the person adds. Answers quote them in their own labelled block;
//  they never count as evidence in your documents or in a case.
//

import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

struct ReferenceShelfView: View {
    @Environment(AppState.self) private var appState
    let onDone: () -> Void
    @State private var folders: [ReferenceShelfRepository.Folder] = []
    @State private var documents: [UUID: [ReferenceShelfRepository.DocumentSummary]] = [:]
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reference shelf").font(.title3.bold())
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.cancelAction)
            }
            Text("Add folders of reference documents — laws, rules, manuals, guidelines. When your documents don't answer a question, or you ask what a rule or term means, the answer shows matching passages from the shelf in a separate block labelled “From your reference shelf”. Shelf documents are never treated as evidence and never become part of a case.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { addFolder() } label: { Label("Add a folder…", systemImage: "folder.badge.plus") }
                    .disabled(working)
                Button { reread() } label: { Label("Read again", systemImage: "arrow.clockwise") }
                    .disabled(working || folders.isEmpty)
                    .help("Read changed files in every shelf folder again.")
                if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if folders.isEmpty {
                Text("The shelf is empty.").foregroundStyle(.secondary)
            }
            List {
                ForEach(folders) { f in
                    Section {
                        ForEach(documents[f.id] ?? []) { d in
                            HStack {
                                Image(systemName: d.status == "read" ? "doc.text" : "exclamationmark.triangle")
                                    .foregroundStyle(d.status == "read" ? Color.secondary : Color.orange)
                                Text(d.title).lineLimit(1)
                                Spacer()
                                Text(d.status == "read" ? "\(d.passageCount) passage(s)" : (d.detail ?? "Could not be read"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack {
                            Text(f.label)
                            Spacer()
                            Button("Remove from shelf", role: .destructive) { remove(f) }
                                .buttonStyle(.borderless).font(.caption)
                                .help("Take this folder off the shelf. Your files are not touched.")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .task { await reload() }
    }

    private func reload() async {
        guard let shelf = appState.referenceShelf else { return }
        do {
            let fs = try await shelf.folders()
            var docs: [UUID: [ReferenceShelfRepository.DocumentSummary]] = [:]
            for f in fs { docs[f.id] = try await shelf.documents(folderID: f.id) }
            folders = fs; documents = docs
        } catch {
            KalsmritikoshLog.ui.error("Reference shelf view: \(String(describing: error), privacy: .public)")
            message = "The shelf could not be read."
        }
    }

    private func summary(_ r: ReferenceShelfReader.Report?) -> String {
        guard let r else { return "The shelf could not be updated." }
        var s = "Read \(r.read) document(s); \(r.unchanged) unchanged; \(r.unreadable) could not be read."
        if r.skippedNotDocuments > 0 { s += " \(r.skippedNotDocuments) file(s) were not documents and were left out." }
        if r.stoppedAtLimit { s += " Stopped at \(ReferenceShelfReader.fileLimit) files." }
        return s
    }

    private func addFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add to shelf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            let report = await appState.addReferenceShelfFolder(url)
            message = summary(report)
            await reload()
            working = false
        }
        #endif
    }

    private func reread() {
        working = true
        Task {
            message = summary(await appState.rereadReferenceShelf())
            await reload()
            working = false
        }
    }

    private func remove(_ f: ReferenceShelfRepository.Folder) {
        guard let shelf = appState.referenceShelf else { return }
        Task {
            do { try await shelf.removeFolder(id: f.id) } catch {
                KalsmritikoshLog.ui.error("Reference shelf remove failed: \(String(describing: error), privacy: .public)")
                message = "The folder could not be removed."
            }
            await reload()
        }
    }
}
