//
//  CaseStoryView.swift
//  Kalsmritikosh
//
//  "Tell me the whole story of X." Type a subject — a patent number, a person, a
//  project — and get a cited, chronological dossier assembled from your ingested
//  documents: overview, parties, timeline, clauses, roadblocks, gaps, sources.
//  Export it as markdown or a tamper-evident receipt. On-device, evidence-first.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct CaseStoryView: View {
    @Environment(AppState.self) private var appState
    @State private var subject: String = ""
    @State private var markdown: String?
    @State private var generating = false
    @State private var didRun = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if generating {
                ProgressView("Assembling the story from your documents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let markdown {
                result(markdown)
            } else if didRun {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Nothing about that in your archive yet. Try the patent number, a party name, or a keyword from the documents.",
                          systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                    FirstRunHint(message: "If the archive is still empty, add your files first — stories are built only from what's been read.")
                }
                Spacer()
            } else {
                Spacer()
            }
        }
        .padding(16)
        .navigationTitle("Case Story")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell the whole story of…").font(.title3.bold())
            Text("A patent number, a person, a company, a project. The app gathers everything it extracted about it into one cited, chronological file — overview, parties, timeline, clauses, roadblocks, and what's still missing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("e.g. the patent number, or a party's name…", text: $subject)
                    .textFieldStyle(.plain)
                    .onSubmit { run() }
                Button("Build the story") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(subject.trimmingCharacters(in: .whitespaces).count < 2)
                    .guidance(GuidanceTip("Build the story",
                                          what: "Reconstructs the whole cited story of a subject — timeline, parties, key clauses, roadblocks and gaps — from your evidence.",
                                          enabledWhen: "Name a subject (at least two characters) first."),
                              enabled: subject.trimmingCharacters(in: .whitespaces).count >= 2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private func result(_ md: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Story of \u{201C}\(subject)\u{201D}").font(.headline)
                Spacer()
                Menu {
                    Button { save(md, ext: "md", type: "md") } label: { Label("Markdown (.md)", systemImage: "doc.text") }
                    Button { exportReceipt(md) } label: { Label("Verifiable receipt (.json)", systemImage: "checkmark.seal") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .fixedSize()
            }
            ScrollView {
                Text(renderMarkdown(md))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func renderMarkdown(_ raw: String) -> AttributedString {
        (try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
    }

    private func run() {
        let term = subject
        generating = true
        Task {
            let md = await appState.subjectDossier(term: term)
            await MainActor.run { markdown = md; generating = false; didRun = true }
        }
    }

    private func save(_ text: String, ext: String, type: String) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        if let t = UTType(filenameExtension: type) { panel.allowedContentTypes = [t] }
        let safe = subject.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = "case-story-\(safe.isEmpty ? "subject" : safe).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    /// Seal the story as a single-entry tamper-evident receipt (the whole file
    /// pinned to its own hash), re-checkable in Verify Receipt.
    private func exportReceipt(_ md: String) {
        let sealed = VerifiableReceipt.seal(
            title: "Case story: \(subject)",
            drafts: [ReceiptDraft(claim: "Case story of \(subject)", source: "Kalsmritikosh (assembled from cited sources)", passage: md)]
        )
        save(VerifiableReceipt.json(sealed), ext: "json", type: "json")
    }
}
