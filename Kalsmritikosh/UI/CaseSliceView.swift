//
//  CaseSliceView.swift
//  Kalsmritikosh
//
//  I-10 — make a signed, redacted slice from a tag, or open one read-only.
//

import SwiftUI
import UniformTypeIdentifiers
import os

struct CaseSliceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [UserTag] = []
    @State private var tag = ""
    @State private var terms = ""
    @State private var status: String?
    @State private var opened: CaseSlice?
    @State private var openCheck: CaseSlice.Check?
    @State private var choosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signed case slices").font(.title3.bold())
            Text("Share part of a case as one signed, redacted, read-only file. Emails and phone numbers are always removed; add names or numbers to remove below. Anyone with Investigation Docs Made Easy can open it and see whether it was changed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tags.isEmpty {
                Text("Tag the documents you want to share first (Tags must be on).").font(.callout).foregroundStyle(.orange)
            } else {
                Picker("Documents tagged", selection: $tag) {
                    ForEach(tags) { Text("\($0.name) (\($0.count))").tag($0.name) }
                }
                TextField("Also remove (comma-separated names, numbers)", text: $terms).textFieldStyle(.roundedBorder)
                Button("Export slice…") { Task { await export() } }.disabled(tag.isEmpty)
            }
            Divider()
            Button("Open a slice…") { choosingFile = true }
            if let s = opened {
                switch openCheck {
                case .valid(let fp)?: Label("Signature valid — signed by key \(fp). Nothing was changed.", systemImage: "checkmark.seal").foregroundStyle(.green)
                case .invalid?: Label("Signature FAILED — this slice was changed or is not genuine.", systemImage: "xmark.seal").foregroundStyle(.red)
                default: Label("Not signed.", systemImage: "seal").foregroundStyle(.orange)
                }
                List {
                    Section("Documents") { ForEach(s.documents, id: \.ref) { Text("[\($0.ref)] \($0.name)") } }
                    Section("Events") { ForEach(Array(s.events.enumerated()), id: \.offset) { _, e in Text("\(e.date.prefix(10)) — \(e.title)  [\(e.ref)]") } }
                    Section("Passages") { ForEach(Array(s.passages.enumerated()), id: \.offset) { _, p in Text("[\(p.ref)] \(p.text)").font(.caption) } }
                }
                .frame(minHeight: 240)
                Text("\(s.redaction.removed) value(s) were redacted when this slice was made.").font(.caption2).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 600)
        .task {
            tags = (try? await appState.tagsRepository?.allTags()) ?? []
            tag = tags.first?.name ?? ""
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(CaseSlice.self, from: data) {
                opened = s; openCheck = s.verify()
            } else {
                status = "That file is not an Investigation Docs Made Easy slice."
            }
        }
    }

    private func export() async {
        let list = terms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let slice = await appState.caseSlice(tagName: tag, customTerms: list) else {
            status = "Could not build the slice (no tagged documents, or no signing key)."
            return
        }
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "slice-\(tag).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(slice).write(to: url, options: .atomic)
            status = "Saved: \(slice.documents.count) documents, \(slice.events.count) events, \(slice.passages.count) passages."
        } catch {
            status = error.localizedDescription
            KalsmritikoshLog.ui.error("Slice save failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}
