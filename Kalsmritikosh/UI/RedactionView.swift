//
//  RedactionView.swift
//  Kalsmritikosh
//
//  UI for real burn-in PDF redaction (see PDFRedactionService). Pick a PDF,
//  list the terms to remove, and produce a verified-clean redacted copy —
//  the words are destroyed, not just covered. If any term survives, the
//  operation fails closed and no file is offered.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

/// Minimal FileDocument wrapper so the redacted bytes can be saved with the
/// system export panel.
struct RedactedPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

public struct RedactionView: View {
    @Environment(AppState.self) private var appState

    @State private var sourceURL: URL?
    @State private var termsText: String = ""
    @State private var caseSensitive = false
    @State private var running = false
    @State private var result: PDFRedactionResult?
    @State private var errorMessage: String?

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: RedactedPDFDocument?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                sourcePicker

                termsEditor

                Toggle("Match case exactly", isOn: $caseSensitive)
                    .toggleStyle(.switch)
                    .disabled(running)

                actionRow

                if let result { resultCard(result) }
                if let errorMessage { errorCard(errorMessage) }

                explainer
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Redaction")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { res in
            switch res {
            case .success(let url):
                sourceURL = url
                result = nil
                errorMessage = nil
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: defaultOutputName
        ) { res in
            if case .failure(let err) = res { errorMessage = err.localizedDescription }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Real redaction", systemImage: "eye.slash")
                .font(.title2.bold())
            Text("Removes the words from the PDF, not just a black box on top. Redacted pages are flattened so the hidden text can't be selected, copied, or extracted — and the result is re-checked to prove nothing survived.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourcePicker: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceURL?.lastPathComponent ?? "No PDF chosen")
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sourceURL == nil ? "Choose the PDF you want to redact" : "Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose PDF…") { showImporter = true }
                    .disabled(running)
            }
        }
    }

    private var termsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Terms to remove")
                .font(.headline)
            Text("One per line, or comma-separated — names, numbers, addresses. Every occurrence is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $termsText)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(running)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await runRedaction() }
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Redact", systemImage: "eye.slash.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || sourceURL == nil || parsedTerms.isEmpty)

            if let result, result.verified {
                Button {
                    exportDoc = RedactedPDFDocument(data: result.data)
                    showExporter = true
                } label: {
                    Label("Save redacted PDF…", systemImage: "square.and.arrow.down")
                }
            }
            Spacer()
        }
    }

    private func resultCard(_ r: PDFRedactionResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Verified clean", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                HStack(spacing: 24) {
                    stat("\(r.matchCount)", "matches removed")
                    stat("\(r.redactedPageCount)", "pages flattened")
                    stat("\(r.pageCount)", "pages total")
                }
                Text("A re-parse of the output found none of the protected terms. Save it above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        GroupBox {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why this beats a black box")
                .font(.subheadline.bold())
            Text("Most tools draw a rectangle over the text and leave the words underneath — copy-paste or a text dump reveals them, which has caused real disclosure leaks. Here, any page with a match is rebuilt as an image with no text layer, so the words are gone. Pages with nothing to redact keep their selectable text. The output is then searched again for every term, and if even one survives, no file is produced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Logic

    private var parsedTerms: [String] {
        termsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var defaultOutputName: String {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "document"
        return "\(base)-redacted"
    }

    private func runRedaction() async {
        guard let url = sourceURL else { return }
        running = true
        result = nil
        errorMessage = nil
        let terms = parsedTerms
        let caseSensitive = self.caseSensitive

        let outcome: Result<PDFRedactionResult, Error> = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try PDFRedactionService().redact(source: url, terms: terms, caseSensitive: caseSensitive)
                return .success(r)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let r):
            result = r
        case .failure(let err):
            errorMessage = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            KalsmritikoshLog.ui.error("PDF redaction failed: \(err.localizedDescription, privacy: .public)")
        }
        running = false
    }
}
