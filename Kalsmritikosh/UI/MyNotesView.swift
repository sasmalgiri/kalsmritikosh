//
//  MyNotesView.swift
//  Kalsmritikosh
//
//  P-2 — write and edit your own notes in Markdown. Notes live as `.md` files in the app's
//  Notes folder (NotesStore), which is read like any source, so a saved note is searchable
//  and can be asked about. Every save keeps the earlier text as a version; deleting moves
//  the note to the trash, from where it can be put back.
//

import SwiftUI
import AppKit
import os

struct MyNotesView: View {
    @Environment(AppState.self) private var appState

    @State private var notes: [NotesStore.Note] = []
    @State private var trashed: [NotesStore.Note] = []
    @State private var selection: URL?
    @State private var text = ""
    @State private var savedText = ""
    @State private var preview = false
    @State private var newTitle = ""
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var showVersions = false
    @State private var showTrash = false
    @State private var message: String?
    /// X-3 — rich-text notes (when "Rich text notes and PDF marks" is on).
    @State private var newFormat: NotesStore.Format = .markdown
    @State private var rich = NSAttributedString()
    @State private var savedRich = NSAttributedString()

    private let store = NotesStore.standard

    private var isRich: Bool { selection.map { NotesStore.format(of: $0) == .richText } ?? false }
    private var dirty: Bool {
        guard selection != nil else { return false }
        return isRich ? !rich.isEqual(to: savedRich) : text != savedText
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            editor.frame(minWidth: 380)
        }
        .frame(minWidth: 680, minHeight: 440)
        .task { reload() }
        .onDisappear { saveIfNeeded() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your notes").font(.title3.bold())
            if ProductModuleFlags.isEnabled(.richDocuments) {
                Picker("Format", selection: $newFormat) {
                    Text("Markdown").tag(NotesStore.Format.markdown)
                    Text("Rich text").tag(NotesStore.Format.richText)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                TextField("New note title", text: $newTitle)
                    .onSubmit(create)
                Button("New", action: create)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List(selection: Binding(get: { selection }, set: { open($0) })) {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.title).lineLimit(1)
                        Text(note.modified, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(note.url)
                }
            }
            .overlay {
                if notes.isEmpty {
                    Text("No notes yet. Give one a title above.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            Button {
                showTrash.toggle()
            } label: {
                Label("Trash (\(trashed.count))", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(trashed.isEmpty)
            .popover(isPresented: $showTrash) { trashList }
        }
        .padding(10)
    }

    private var trashList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deleted notes").font(.headline)
            Text("Put a note back to edit it again. What the archive learned from a note stays, like any source you remove.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(trashed) { note in
                HStack {
                    Text(note.title).lineLimit(1)
                    Spacer()
                    Button("Put back") { putBack(note) }
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let note = selection {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if renaming {
                        TextField("Title", text: $renameTitle).onSubmit { rename(note) }
                        Button("Rename") { rename(note) }
                        Button("Cancel") { renaming = false }
                    } else {
                        Text(note.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                        Button {
                            renameTitle = note.deletingPathExtension().lastPathComponent; renaming = true
                        } label: { Label("Rename", systemImage: "pencil").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    if !isRich {
                        Picker("", selection: $preview) {
                            Text("Edit").tag(false)
                            Text("Preview").tag(true)
                        }
                        .pickerStyle(.segmented).frame(width: 150)
                        .accessibilityLabel("Edit or preview")
                    }
                    Button {
                        showVersions.toggle()
                    } label: { Label("Versions", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly) }
                    .help("Earlier versions of this note")
                    .popover(isPresented: $showVersions) { versionList(note) }
                    Button(role: .destructive) { delete(note) } label: {
                        Label("Move to Trash", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .help("Move this note to the trash")
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!dirty)
                }
                if isRich {
                    RichTextEditor(text: $rich)
                        .accessibilityLabel("Note text, rich text")
                } else if preview {
                    ScrollView {
                        Text(Self.rendered(text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .accessibilityLabel("Note text, in Markdown")
                }
                HStack {
                    Text(dirty ? "Not saved" : "Saved — searchable once it has been read in")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(10)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text").font(.largeTitle).foregroundStyle(.secondary)
                Text("Choose a note, or start a new one.").foregroundStyle(.secondary)
                Text("Notes are written in Markdown and become part of your archive: you can search them and ask about them.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func versionList(_ note: URL) -> some View {
        let versions = store?.versions(of: note) ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text("Earlier versions").font(.headline)
            if versions.isEmpty {
                Text("None yet. Each save keeps the text it replaces.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(versions) { v in
                        HStack {
                            Text(v.savedAt, format: .dateTime.day().month().year().hour().minute().second())
                            Spacer()
                            Button("Restore") { restore(v, to: note) }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            Text("Restoring keeps the current text as a version too.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
    }

    /// Markdown rendered with its line breaks kept; plain text when it does not parse.
    static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    // MARK: - Actions

    private func reload() {
        notes = store?.list() ?? []
        trashed = store?.trashed() ?? []
    }

    private func open(_ url: URL?) {
        guard url != selection else { return }
        saveIfNeeded()
        selection = url
        renaming = false
        message = nil
        guard let url, let store else { text = ""; savedText = ""; return }
        do {
            if NotesStore.format(of: url) == .richText {
                rich = try store.readRich(url); savedRich = rich
                text = ""; savedText = ""
                return
            }
            text = try store.read(url); savedText = text
        } catch {
            KalsmritikoshLog.app.error("Note read failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
            text = ""; savedText = ""
        }
    }

    private func create() {
        guard let store else { return }
        do {
            let url = try store.create(title: newTitle,
                                       format: ProductModuleFlags.isEnabled(.richDocuments) ? newFormat : .markdown)
            newTitle = ""
            reload()
            open(url)
            Task { await appState.readNote(url) }
        } catch {
            KalsmritikoshLog.app.error("Note create failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func saveIfNeeded() { if dirty { save() } }

    private func save() {
        guard let store, let note = selection else { return }
        do {
            let changed = isRich ? try store.saveRich(rich, to: note) : try store.save(text, to: note)
            if changed {
                savedText = text
                savedRich = rich
                reload()
                Task { await appState.readNote(note) }
            }
        } catch {
            KalsmritikoshLog.app.error("Note save failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func rename(_ note: URL) {
        guard let store else { return }
        saveIfNeeded()
        do {
            let url = try store.rename(note, to: renameTitle)
            renaming = false
            selection = url
            reload()
            Task { await appState.readNote(url) }
        } catch {
            KalsmritikoshLog.app.error("Note rename failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func delete(_ note: URL) {
        guard let store else { return }
        saveIfNeeded()
        do {
            try store.delete(note)
            selection = nil; text = ""; savedText = ""
            reload()
        } catch {
            KalsmritikoshLog.app.error("Note delete failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func putBack(_ note: NotesStore.Note) {
        guard let store else { return }
        do {
            let url = try store.restoreFromTrash(note.url)
            showTrash = false
            reload()
            open(url)
            Task { await appState.readNote(url) }
        } catch {
            KalsmritikoshLog.app.error("Note restore failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func restore(_ version: NotesStore.Version, to note: URL) {
        guard let store else { return }
        do {
            try store.restore(version, to: note)
            if NotesStore.format(of: note) == .richText {
                rich = try store.readRich(note); savedRich = rich
            } else {
                text = try store.read(note); savedText = text
            }
            showVersions = false
            reload()
            Task { await appState.readNote(note) }
        } catch {
            KalsmritikoshLog.app.error("Note version restore failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }
}

/// X-3 — an editable rich-text view (bold, italic, underline, lists, links, fonts, colours:
/// the standard Format menu and ⌘B/⌘I/⌘U work in it).
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = true
        view.importsGraphics = false          // pictures go in as their own documents
        view.allowsUndo = true
        view.usesFontPanel = true
        view.usesRuler = true
        view.isAutomaticLinkDetectionEnabled = true
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        if !storage.isEqual(to: text) {
            context.coordinator.updating = true
            storage.setAttributedString(text)
            context.coordinator.updating = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var updating = false
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = NSAttributedString(attributedString: view.attributedString())
        }
    }
}
