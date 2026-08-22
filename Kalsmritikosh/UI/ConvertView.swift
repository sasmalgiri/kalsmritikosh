//
//  ConvertView.swift
//  Kalsmritikosh
//
//  Kalsmritikosh-as-parser. The user drops any supported file in here, picks
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
        case html = "HTML"
        case csv = "CSV"
        case pdf = "PDF"
        case rtf = "RTF (Word)"
        case docx = "Word (.docx)"
        case xlsx = "Excel (.xlsx)"
        case png = "Image (PNG)"

        public var id: String { rawValue }

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .markdown:  return "md"
            case .json:      return "json"
            case .html:      return "html"
            case .csv:       return "csv"
            case .pdf:       return "pdf"
            case .rtf:       return "rtf"
            case .docx:      return "docx"
            case .xlsx:      return "xlsx"
            case .png:       return "png"
            }
        }

        /// Binary formats produce Data (no meaningful text preview).
        public var isBinary: Bool {
            switch self {
            case .plainText, .markdown, .json, .html, .csv: return false
            case .pdf, .rtf, .docx, .xlsx, .png: return true
            }
        }
    }

    @State private var importerPresented: Bool = false
    @State private var inputs: [URL] = []
    @State private var outputFormat: OutputFormat = .plainText
    @State private var converting: Bool = false
    @State private var output: String = ""
    /// Binary payload for PDF/RTF/DOCX/XLSX/PNG output (nil for text formats).
    @State private var outputData: Data? = nil
    @State private var statusLine: String = ""
    /// Hybrid Apple-AI + NLP proofread of the extracted text before display.
    @State private var aiProofread: Bool = true

    public init() {}

    @State private var dropTargeted: Bool = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                dropZone
                if !inputs.isEmpty { inputsList }
                controls
                outputArea
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AuroraBackdrop(intensity: 0.7))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.right.doc.on.clipboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Theme.brand.opacity(0.3), radius: 8, y: 3)
                Text("Convert")
                    .font(Theme.display(34, .bold))
                InfoPopoverButton(
                    title: "How Convert works",
                    message: "Add files, choose an output format, then Convert and Save as… It's one-shot — nothing here is added to your knowledge base.",
                    systemImage: "arrow.right.doc.on.clipboard",
                    bullets: [
                        "Reads PDF, Word, Excel, images (OCR), email/PST/NSF, audio & video",
                        "Writes text, Markdown, JSON, HTML, CSV, PDF, RTF, Word, Excel, PNG",
                        "AI proofread fixes OCR typos but never changes numbers or dates"
                    ]
                )
                Spacer()
            }
            Text("A one-shot file converter — nothing here is saved to your knowledge base. Reads PDF, Word, Excel, images (OCR), email/PST/NSF, and audio & video (transcribed); exports to text, Markdown, JSON, HTML, CSV, PDF, RTF, Word, Excel, or PNG.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
            Label("1. Add files   2. Pick an output format   3. Convert, then Save as…", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(dropTargeted ? Theme.brand : .secondary)
                .symbolEffect(.bounce, value: dropTargeted)
            Text("Drop files here")
                .font(.headline)
            Text("or click **Add file(s)…** below")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(dropTargeted ? Theme.brand.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(
                    dropTargeted ? Theme.brand : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: [7, 5])
                )
        )
        .animation(Theme.springFast, value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
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
            .buttonStyle(.pressable)
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    inputs.append(contentsOf: urls)
                }
            }

            Text("Output:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("", selection: $outputFormat) {
                ForEach(OutputFormat.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("The format your files are converted to.")

            Toggle(isOn: $aiProofread) {
                Label("AI proofread", systemImage: "wand.and.stars")
            }
            .toggleStyle(.checkbox)
            .help("Hybrid on-device Apple AI + NLP: fixes OCR typos/names using the document's own context. Never changes numbers, dates or IDs.")

            Spacer()

            if !output.isEmpty {
                Button { saveOutput() } label: {
                    Label("Save as…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.pressable)
                Button { copyOutput() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.pressable)
            }

            convertButton
        }
    }

    private var convertButton: some View {
        let disabled = inputs.isEmpty || converting
        return Button {
            Task { await runConversion() }
        } label: {
            HStack(spacing: 6) {
                if converting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(converting ? "Converting…" : "Convert")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.brandGradient(), in: Capsule())
            .shadow(color: Theme.brand.opacity(0.3), radius: 6, y: 2)
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .guidance(GuidanceTip("Convert",
                              what: "Turns the loaded file into the chosen format, fully on-device — nothing is uploaded.",
                              enabledWhen: "Choose a file and a target format first."),
                  enabled: !disabled)
    }

    // MARK: - Inputs list

    @ViewBuilder
    private var inputsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(inputs.enumerated()), id: \.offset) { idx, url in
                inputRow(idx: idx, url: url)
            }
        }
    }

    @ViewBuilder
    private func inputRow(idx: Int, url: URL) -> some View {
        let typeLabel = SourceType.detect(from: url).rawValue
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(Theme.brand)
            Text(url.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(typeLabel)
                .font(.caption2.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.brand.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.brand)
            Button {
                withAnimation(Theme.springFast) { _ = inputs.remove(at: idx) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .cardSurface(cornerRadius: Theme.Radius.sm)
        .transition(.popIn)
    }

    // MARK: - Output area

    @ViewBuilder
    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text(output.isEmpty ? "Output will appear here after you convert." : output)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(minHeight: 220, maxHeight: 420)
            .cardSurface(cornerRadius: Theme.Radius.md)
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
        outputData = nil
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

        // Hybrid Apple-AI + NLP proofread of the extracted text before it's
        // shown. Non-destructive + facts-preserving; falls back to the raw
        // text if no model is available or a rewrite looks unsafe.
        var contributingExperts = Set<String>()
        if aiProofread, !pieces.isEmpty {
            statusLine = "Proofreading with on-device AI…"
            let corrector = AITextCorrector()
            var proofed: [(URL, KnowledgeObject)] = []
            for (url, ko) in pieces {
                let result = await corrector.correct(ko.content, using: appState.capabilities)
                result.experts.forEach { contributingExperts.insert($0) }
                if result.corrected {
                    proofed.append((url, KnowledgeObject(
                        sourceFile: ko.sourceFile,
                        sourceType: ko.sourceType,
                        content: result.text,
                        metadata: ko.metadata
                    )))
                } else {
                    proofed.append((url, ko))
                }
            }
            pieces = proofed
        }

        if outputFormat.isBinary {
            let records = pieces.map {
                ExportRecord(title: $0.0.lastPathComponent, sourceType: $0.1.sourceType.rawValue, text: $0.1.content)
            }
            let data: Data?
            switch outputFormat {
            case .pdf:  data = DocumentExporter.pdf(records)
            case .rtf:  data = DocumentExporter.rtf(records)
            case .docx: data = DocumentExporter.docx(records)
            case .xlsx: data = DocumentExporter.xlsx(records)
            case .png:  data = DocumentExporter.png(records)
            default:    data = nil
            }
            outputData = data
            if let data {
                output = "✅ \(outputFormat.rawValue) ready — \(pieces.count) record\(pieces.count == 1 ? "" : "s"), \(Self.humanBytes(data.count)).\nUse “Save as…” to write the file."
            } else {
                output = "Couldn't build \(outputFormat.rawValue) output for these files."
            }
        } else {
            outputData = nil
            output = format(pieces: pieces, failures: failed, as: outputFormat)
        }

        var status = "Parsed \(pieces.count) record\(pieces.count == 1 ? "" : "s"), failed \(failed.count)"
        if !contributingExperts.isEmpty {
            status += " · proofread (\(contributingExperts.sorted().joined(separator: "+")))"
        }
        statusLine = status
    }

    private static func humanBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
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
        case .html:
            var out = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>Kalsmritikosh conversion</title>\n"
            out += "<style>body{font:14px -apple-system,system-ui,sans-serif;max-width:820px;margin:2rem auto;padding:0 1rem;color:#1c1c1e}"
            out += "h2{border-bottom:1px solid #ddd;padding-bottom:.25rem} .meta{color:#8a8a8e;font-size:12px} pre{white-space:pre-wrap;word-wrap:break-word} .fail{color:#c0392b}</style>\n</head>\n<body>\n"
            for (url, ko) in pieces {
                out += "<h2>\(Self.htmlEscape(url.lastPathComponent))</h2>\n"
                out += "<div class=\"meta\">\(Self.htmlEscape(ko.sourceType.rawValue))</div>\n"
                out += "<pre>\(Self.htmlEscape(ko.content))</pre>\n"
            }
            for (url, err) in failures {
                out += "<p class=\"fail\">FAILED: \(Self.htmlEscape(url.lastPathComponent)) — \(Self.htmlEscape(err))</p>\n"
            }
            out += "</body>\n</html>\n"
            return out
        case .csv:
            var out = "file,source_type,content\n"
            for (url, ko) in pieces {
                out += Self.csvRow([url.lastPathComponent, ko.sourceType.rawValue, ko.content])
            }
            for (url, err) in failures {
                out += Self.csvRow([url.lastPathComponent, "ERROR", err])
            }
            return out
        case .pdf, .rtf, .docx, .xlsx, .png:
            return ""   // binary formats are produced via DocumentExporter, not here
        }
    }

    /// RFC-4180 CSV row: quote every field, double internal quotes.
    private static func csvRow(_ fields: [String]) -> String {
        fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",") + "\n"
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func jsonMetadata(_ meta: [String: AnyCodable]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in meta {
            out[k] = jsonAny(v.value)
        }
        return out
    }

    private nonisolated static func jsonAny(_ v: AnyCodable.AnySendable) -> Any {
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
        let contentType: UTType = {
            switch outputFormat {
            case .json:      return .json
            case .markdown:  return UTType(filenameExtension: "md") ?? .plainText
            case .html:      return .html
            case .csv:       return .commaSeparatedText
            case .plainText: return .plainText
            case .pdf:       return .pdf
            case .rtf:       return .rtf
            case .png:       return .png
            case .docx:      return UTType(filenameExtension: "docx") ?? .data
            case .xlsx:      return UTType(filenameExtension: "xlsx") ?? .data
            }
        }()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "kalsmritikosh-convert.\(outputFormat.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            let data = outputData ?? output.data(using: .utf8) ?? Data()
            try? data.write(to: url, options: .atomic)
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
