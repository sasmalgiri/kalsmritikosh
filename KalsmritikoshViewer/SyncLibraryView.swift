//
//  SyncLibraryView.swift
//  KalsmritikoshViewer
//
//  X-6 — browse, search and edit the archive in your sync folder on iPhone or iPad.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import VisionKit

struct SyncLibraryView: View {
    @State private var library = SyncLibrary()
    @State private var choosing = false
    @State private var passphrase = ""
    @State private var query = ""
    @State private var scanning = false
    @State private var newNote = false

    var body: some View {
        NavigationStack {
            Group {
                if library.isOpen { content } else { setup }
            }
            .navigationTitle("Your archive")
            .toolbar {
                if library.isOpen {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if VNDocumentCameraViewController.isSupported {
                            Button("Scan", systemImage: "doc.viewfinder") { scanning = true }
                        }
                        Button("New note", systemImage: "square.and.pencil") { newNote = true }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Disconnect this device", role: .destructive) { library.disconnect() }
                    }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.choose(url) }
            }
            .sheet(isPresented: $scanning) {
                DocumentScanner { images in Task { await library.addScan(images) } }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $newNote) {
                NoteEditor(library: library, note: nil)
            }
        }
        .task { await library.restore() }
    }

    private var setup: some View {
        Form {
            Section {
                Text("Open the sync folder your Mac uses (in iCloud Drive, Dropbox or another Files location), then enter the same sync passphrase. Nothing is sent anywhere by this app: the folder's own service moves the files.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Choose sync folder…") { choosing = true }
            }
            if library.needsPassphrase {
                Section("Passphrase") {
                    SecureField("Sync passphrase", text: $passphrase)
                    Button("Open") { Task { await library.unlock(passphrase); passphrase = "" } }
                        .disabled(passphrase.isEmpty || library.busy)
                }
            }
            if let p = library.problem { Section { Text(p).foregroundStyle(.red) } }
        }
    }

    private var content: some View {
        let results = library.search(query)
        return List {
            if let p = library.problem { Section { Text(p).font(.caption).foregroundStyle(.orange) } }
            Section("Notes") {
                ForEach(results.notes, id: \.self) { note in
                    NavigationLink((note.name as NSString).deletingPathExtension) {
                        NoteEditor(library: library, note: note)
                    }
                }
                if results.notes.isEmpty { Text("No notes").foregroundStyle(.secondary) }
            }
            Section("Documents") {
                ForEach(results.docs) { doc in
                    NavigationLink {
                        DocumentDetail(library: library, doc: doc)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(doc.title).lineLimit(2)
                            if doc.blobSHA == nil {
                                Text("On your Mac — its marks and tags show here").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if results.docs.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
            }
            Section {
                Text("Questions are answered on your Mac, where the full archive is.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Search notes, titles, highlights")
        .refreshable { await library.refresh() }
        .overlay { if library.busy { ProgressView() } }
    }
}

struct DocumentDetail: View {
    let library: SyncLibrary
    let doc: SyncReplay.Document
    @State private var newTag = ""
    @State private var quote = ""
    @State private var note = ""
    @State private var preview: URL?

    var body: some View {
        Form {
            Section {
                Text(doc.title).font(.headline)
                if doc.blobSHA != nil {
                    Button("Open", systemImage: "eye") { preview = library.previewFile(for: doc) }
                } else {
                    Text("This file lives on your Mac; open it there.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Tags") {
                ForEach(library.replay.tags(of: doc), id: \.self) { t in
                    HStack {
                        Text(t)
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await library.untag(doc, t) } }.font(.caption)
                    }
                }
                HStack {
                    TextField("Add a tag", text: $newTag)
                    Button("Add") { Task { await library.tag(doc, with: newTag); newTag = "" } }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Groups") {
                ForEach(library.replay.groups(of: doc), id: \.self) { Text($0) }
                Menu("Put in a group") {
                    ForEach(library.replay.liveGroups, id: \.id) { g in
                        Button(g.name) { Task { await library.file(doc, into: g.id) } }
                    }
                }
                .disabled(library.replay.liveGroups.isEmpty)
            }
            Section("Highlights") {
                ForEach(Array(library.replay.highlights(of: doc).enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading) {
                        Text("\u{201C}\(h.quote)\u{201D}")
                        if let n = h.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TextField("Passage to highlight (exact words)", text: $quote, axis: .vertical)
                TextField("Your note (optional)", text: $note)
                Button("Highlight") { Task { await library.highlight(doc, quote: quote, note: note); quote = ""; note = "" } }
                    .disabled(quote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Document")
        .quickLookPreview($preview)
    }
}

struct NoteEditor: View {
    let library: SyncLibrary
    let note: SyncFileOp?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if note == nil { TextField("Title", text: $name) }
                TextEditor(text: $text).frame(minHeight: 300).font(.body.monospaced())
            }
            .navigationTitle(note.map { ($0.name as NSString).deletingPathExtension } ?? "New note")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await library.saveNote(name: name, text: text, editing: note); dismiss() }
                    }
                    .disabled(note == nil && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let note { text = library.text(of: note) } else { text = "" }
        }
    }
}

/// VisionKit's document camera: the pages come back as images.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        init(onScan: @escaping ([UIImage]) -> Void) { self.onScan = onScan }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            controller.dismiss(animated: true)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { controller.dismiss(animated: true) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }
    }
}
