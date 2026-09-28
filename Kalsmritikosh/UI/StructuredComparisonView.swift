//
//  StructuredComparisonView.swift
//  Kalsmritikosh
//
//  G3 Workflow C — the comparison brief flow. Pick two or more documents; the
//  app reads what each one asserts field by field and renders a deterministic
//  brief: where the sources AGREE, where they genuinely DISAGREE, where they
//  merely use DIFFERENT UNITS (not a conflict), and what no source settles.
//  Fields are discovered from the documents themselves — nothing to configure,
//  nothing summarized-away. Export the brief as Markdown.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct StructuredComparisonView: View {
    @Environment(AppState.self) private var appState
    @State private var documents: [KnowledgeObjectSummaryRow] = []
    @State private var selection: Set<UUID> = []
    @State private var result: DocumentComparisonResult?
    @State private var comparing = false
    @State private var loadedList = false
    @State private var note: String?

    public init() {}

    public var body: some View {
        HSplitView {
            picker
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            briefPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .navigationTitle("Compare Documents")
        .task { await loadDocuments() }
        .toolbar {
            if let brief = result?.brief {
                ToolbarItem {
                    Button {
                        exportMarkdown(brief)
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    // MARK: - Left: document picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose documents to compare")
                .font(.headline)
            Text("Select two or more. The brief compares the fields they have in common.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !loadedList {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if documents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.title).foregroundStyle(.secondary)
                    Text("No documents yet.").foregroundStyle(.secondary)
                    Button { SurfaceOpener.open(.sources) } label: {
                        Label("Add your files", systemImage: "folder")
                    }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(documents, selection: $selection) { doc in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(doc.sourceFile.lastPathComponent)
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(doc.preview)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(doc.id)
                }
                .listStyle(.inset)

                Button {
                    Task { await run() }
                } label: {
                    Label("Compare \(selection.count) documents", systemImage: "square.split.2x1")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.count < 2 || comparing)
            }
        }
        .padding(12)
    }

    // MARK: - Right: the brief

    @ViewBuilder private var briefPane: some View {
        if comparing {
            ProgressView("Reading what each source says…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            ComparisonBriefView(brief: result.brief) { exportMarkdown(result.brief) }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text(note ?? "Select documents on the left, then Compare.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func loadDocuments() async {
        guard !loadedList else { return }
        let rows = (try? await appState.objects?.recent(limit: 200)) ?? []
        await MainActor.run {
            self.documents = rows
            self.loadedList = true
        }
    }

    private func run() async {
        let ids = Array(selection)
        await MainActor.run { self.comparing = true; self.note = nil }
        let outcome = await appState.compareDocuments(objectIDs: ids)
        await MainActor.run {
            self.comparing = false
            if let outcome {
                self.result = outcome
            } else {
                self.result = nil
                self.note = "These documents don't share comparable fields yet. Pick documents of a similar kind, or add more files."
            }
        }
    }

    private func exportMarkdown(_ brief: ComparisonBrief) {
        #if canImport(AppKit)
        let md = "# Comparison brief\n\n" + brief.text + "\n"
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        panel.nameFieldStringValue = "comparison-brief.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try md.write(to: url, atomically: true, encoding: .utf8) }
        catch { print("Comparison export failed: \(error)") }
        #endif
    }
}
