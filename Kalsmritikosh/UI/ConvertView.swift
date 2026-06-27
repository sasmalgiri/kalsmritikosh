//
//  ConvertView.swift
//  Kalsmritikosh
//
//  Atlas-as-parser. The user drops any supported file in here, picks
//  an output format (Plain text / Markdown / JSON), and gets clean
//  text back from whichever loader handles that format. Nothing is
//  written to the knowledge ledger — this is a one-shot conversion
//  surface that reuses the same best-in-class parsers (PDFKit,
//  Vision OCR, Apple Speech, custom MS-CFB / MS-PST / NSF walkers,
//  MIME / mbox byte-scan splitter, EPUB walker, ZIP).
//
//  Useful when the user wants to:
//    - Pull text out of a scanned PDF
//    - Get a transcript of an interview recording
//    - Extract structured metadata from an email archive
//    - Read the contents of a .pst or .nsf they can't open otherwise
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct ConvertView: View {
    @Environment(AppState.self) private var appState

    public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
        case plainText = "Plain text"
        case markdown = "Markdown"
        case json = "JSON"

        public var id: String { rawValue }

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .markdown:  return "md"
            case .json:      return "json"
            }
        }
    }

    @State private var importerPresented: Bool = false
    @State private var inputs: [URL] = []
    @State private var outputFormat: OutputFormat = .plainText
    @State private var converting: Bool = false
    @State private var output: String = ""
    @State private var statusLine: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            inputsList
            outputArea
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Convert")
                .font(.largeTitle.bold())
            Text("Parse any supported file (PDF, image, audio, email, mbox, PST, NSF, DOCX, XLSX, …) and export clean text, Markdown, or JSON. Nothing is added to your knowledge ledger — this is a one-shot conversion.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                importerPresented = true
            } label: {
                Label("Add file(s)…", systemImage: "doc.badge.plus")
            }
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    inputs.append(contentsOf: urls)
                }
            }

            Picker("Output", selection: $outputFormat) {
                ForEach(OutputFormat.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                Task { await runConversion() }
            } label: {
                if converting {
                    Label("Converting…", systemImage: "hourglass")
                } else {
                    Label("Convert", systemImage: "arrow.right.circle.fill")
                }
            }
            .disabled(inputs.isEmpty || converting)

            Spacer()

            if !output.isEmpty {
                Button {
                    saveOutput()
                } label: {
                    Label("Save as…", systemImage: "square.and.arrow.down")
                }
                Button {
                    copyOutput()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - Inputs list

    @ViewBuilder
    private var inputsList: some View {
        if inputs.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Drop files here or use **Add file(s)…**")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary.opacity(0.4))
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(inputs.enumerated()), id: \.offset) { idx, url in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(SourceType.detect(from: url).rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button {
                            inputs.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
    }

    // MARK: - Output area

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output").font(.headline)
                Spacer()
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(output.isEmpty ? "Output will appear here." : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    inputs.append(url)
                }
            }
        }
    }

    /// Drive the registered LoaderRegistry directly — no DB writes,
    /// no chunking, no embedding. Just the format-specific parser
    /// that the same ingestion pipeline would use, returning content
    /// + metadata for the user.
    private func runConversion() async {
        converting = true
        statusLine = ""
        output = ""
        defer { converting = false }
        let registry = LoaderRegistry.standard()
        var pieces: [(URL, KnowledgeObject)] = []
        var failed: [(URL, String)] = []

        for url in inputs {
            let type = SourceType.detect(from: url)
            let loader = registry.loader(for: type)
            statusLine = "Parsing \(url.lastPathComponent)…"
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let kos = try await loader.ingestMany(fileAt: url, type: type)
                for ko in kos { pieces.append((url, ko)) }
            } catch {
                failed.append((url, "\(error)"))
            }
        }

        output = format(pieces: pieces, failures: failed, as: outputFormat)
        statusLine = "Parsed \(pieces.count) record\(pieces.count == 1 ? "" : "s"), failed \(failed.count)"
    }

    private func format(
        pieces: [(URL, KnowledgeObject)],
        failures: [(URL, String)],
        as fmt: OutputFormat
    ) -> String {
        switch fmt {
        case .plainText:
            var out = ""
            for (url, ko) in pieces {
                out += "═══════════════ \(url.lastPathComponent) ═══════════════\n"
                out += ko.content
                out += "\n\n"
            }
            for (url, err) in failures {
                out += "✗ FAILED: \(url.lastPathComponent) — \(err)\n"
            }
            return out
        case .markdown:
            var out = ""
            for (url, ko) in pieces {
                out += "## \(url.lastPathComponent)\n\n"
                out += "_Source type: `\(ko.sourceType.rawValue)`_\n\n"
                out += ko.content
                out += "\n\n"
            }
            for (url, err) in failures {
                out += "**FAILED — \(url.lastPathComponent)**\n\n```\n\(err)\n```\n\n"
            }
            return out
        case .json:
            var array: [[String: Any]] = []
            for (url, ko) in pieces {
                array.append([
                    "file": url.lastPathComponent,
                    "sourceType": ko.sourceType.rawValue,
                    "content": ko.content,
                    "metadata": Self.jsonMetadata(ko.metadata)
                ])
            }
            for (url, err) in failures {
                array.append([
                    "file": url.lastPathComponent,
                    "error": err
                ])
            }
            if let data = try? JSONSerialization.data(
                withJSONObject: array, options: [.prettyPrinted, .sortedKeys]
            ), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "[]"
        }
    }

    private static func jsonMetadata(_ meta: [String: AnyCodable]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in meta {
            out[k] = jsonAny(v.value)
        }
        return out
    }

    private static func jsonAny(_ v: AnyCodable.AnySendable) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(jsonAny)
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, vv) in o { d[k] = jsonAny(vv) }
            return d
        }
    }

    private func saveOutput() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            outputFormat == .json
                ? UTType.json
                : (outputFormat == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .plainText)
        ]
        panel.nameFieldStringValue = "atlas-convert.\(outputFormat.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? output.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        #endif
    }

    private func copyOutput() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        #endif
    }
}
