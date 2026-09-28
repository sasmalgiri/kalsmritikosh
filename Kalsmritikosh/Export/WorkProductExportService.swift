//
//  WorkProductExportService.swift
//  Kalsmritikosh
//
//  #147 — the ONE file-producing export facade. It turns an already-composed, already-scope-filtered
//  ExportableDocument (from the shared WorkProductAssemblyService — the ONLY authority that decides what
//  evidence may appear) into bytes in any shipped format, and optionally writes them to a user-chosen file.
//  It composes the existing renderers; it does NOT re-decide scope, privilege, or evidence sufficiency —
//  those gates already ran in assembly and are never weakened here.
//
//  Formats: markdown / html / csv / json / rtf (text, via WorkProductExporter), pdf (PDFReportWriter),
//  docx / xlsx (OOXML via DOCXExporter / XLSXExporter). All offline, on-device, no third-party library.
//
//  Optional redaction (RED-001/002): when a RedactionPolicy is supplied, the document's text is redacted
//  (PIIRedactor) and the rendered result is VERIFIED leak-free (RedactionVerifier) BEFORE any bytes are
//  returned or written — a protected term that survives ANY channel refuses the export (fail-closed), it is
//  never emitted. Without a policy, the document is exported as composed (scope/privilege already enforced).
//

import Foundation

/// Every deliverable format the export surface can produce. Superset of the text-only `ExportFormat`.
public enum ExportDeliverableFormat: String, Sendable, CaseIterable, Codable {
    case markdown, html, csv, json, rtf, pdf, docx, xlsx

    public var fileExtension: String { self == .markdown ? "md" : rawValue }
    public var isBinary: Bool { self == .pdf || self == .docx || self == .xlsx }
    public nonisolated var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .html:     return "HTML"
        case .csv:      return "CSV"
        case .json:     return "JSON"
        case .rtf:      return "Rich Text (RTF)"
        case .pdf:      return "PDF"
        case .docx:     return "Word (DOCX)"
        case .xlsx:     return "Excel (XLSX)"
        }
    }
    /// The text-only renderer format, when this deliverable is a text format.
    var textFormat: ExportFormat? {
        switch self {
        case .markdown: return .markdown
        case .html:     return .html
        case .csv:      return .csv
        case .json:     return .json
        case .rtf:      return .rtf
        case .pdf, .docx, .xlsx: return nil
        }
    }
}

public enum WorkProductExportError: Error, Sendable, Equatable {
    /// A protected term survived redaction and would have leaked — the export is refused.
    case redactionLeak(terms: [String])
    case writeFailed(String)
}

public struct WorkProductExportService: Sendable {
    private let redactor = PIIRedactor()
    private let verifier = RedactionVerifier()

    public nonisolated init() {}

    /// Render the document to `format` bytes. When `redaction` is supplied, the document text is redacted and
    /// the rendered projection is verified leak-free first; a surviving protected term throws (fail-closed).
    public func data(for document: ExportableDocument, format: ExportDeliverableFormat,
                     redaction: RedactionPolicy? = nil) throws -> Data {
        let doc = redaction.map { redactedDocument(document, policy: $0) } ?? document

        if let policy = redaction {
            // Verify against the markdown projection of the redacted document — a format-independent, faithful
            // view of every piece of text that reaches the file (prose, table, sources, manifest). Refuse on any leak.
            let projection = WorkProductExporter.render(doc, as: .markdown)
            let leaks = verifier.leaks(in: projection, protectedTerms: policy.customTerms)
            if !leaks.isEmpty {
                throw WorkProductExportError.redactionLeak(terms: Array(Set(leaks.map(\.term))).sorted())
            }
            // F23 — every ENABLED category, not only custom terms: a second pass over every
            // user-text field of the redacted document must find nothing left to redact. Generated
            // metadata (export date, ids, digests) is not user text and is not re-scanned — the
            // phone pattern also matches ISO dates.
            let residue = redactor.redact(Self.userText(doc), policy: policy)
            if residue.redactionCount > 0 {
                throw WorkProductExportError.redactionLeak(terms: residue.categories.sorted())
            }
        }

        if let text = format.textFormat {
            return Data(WorkProductExporter.render(doc, as: text).utf8)
        }
        switch format {
        case .pdf:  return PDFReportWriter.render(doc)
        case .docx: return DOCXExporter.render(doc)
        case .xlsx: return XLSXExporter.render(doc)
        default:    return Data(WorkProductExporter.render(doc, as: .markdown).utf8)   // unreachable; text handled above
        }
    }

    /// Render and write to `url` (atomically). Returns the URL written.
    @discardableResult
    public func write(_ document: ExportableDocument, format: ExportDeliverableFormat, to url: URL,
                      redaction: RedactionPolicy? = nil) throws -> URL {
        let bytes = try data(for: document, format: format, redaction: redaction)
        do { try bytes.write(to: url, options: .atomic) }
        catch { throw WorkProductExportError.writeFailed("\(error)") }
        return url
    }

    // MARK: - Redaction of the renderable document

    /// A copy of the document with all authored text redacted per policy. Citations and the manifest are left
    /// as composed (identifiers/hashes); if a protected term nonetheless appears there, verification refuses
    /// the export rather than emit it.
    /// Every user-text field of a document, joined — what redaction must have cleaned.
    static func userText(_ d: ExportableDocument) -> String {
        var parts: [String] = [d.title]
        parts += [d.subtitle, d.disclaimer].compactMap { $0 }
        for s in d.sections { parts.append(s.title); parts += s.paragraphs }
        if let t = d.table { parts.append(t.title); parts += t.columns; parts += t.rows.flatMap { $0 } }
        for c in d.citations {
            parts += [c.displayLabel, c.sourceTitle]
            parts += [c.authorOrSender, c.locatorText, c.workspaceExhibitLabel].compactMap { $0 }
            if let b = c.bibliographic { parts += [b.title, b.container, b.url].compactMap { $0 }; parts += b.authors }
        }
        parts += [d.manifest.workspaceTitle, d.manifest.reviewStatusSummary].compactMap { $0 }
        parts += d.manifest.knownLimitations
        parts += d.manifest.citationMap.map(\.label)
        return parts.joined(separator: "\n")
    }

    /// F23 (2026-09-28 review) — EVERY user-text field is redacted, not only the prose: citation
    /// labels, titles, authors, locators, exhibit labels and bibliographic text, and the manifest's
    /// workspace title, review summary, limitations and citation-map labels. Identifiers and hashes
    /// (evidence ids, source-version ids, digests) are immutable evidence identity and stay as-is.
    private func redactedDocument(_ d: ExportableDocument, policy: RedactionPolicy) -> ExportableDocument {
        func r(_ s: String) -> String { redactor.redact(s, policy: policy).redactedText }
        let sections = d.sections.map { ExportSection(title: r($0.title), paragraphs: $0.paragraphs.map(r)) }
        let table = d.table.map { ExportTable(title: r($0.title), columns: $0.columns.map(r), rows: $0.rows.map { $0.map(r) }) }
        let citations = d.citations.map { c -> CitationRecord in
            var c = c
            c.displayLabel = r(c.displayLabel)
            c.sourceTitle = r(c.sourceTitle)
            c.authorOrSender = c.authorOrSender.map(r)
            c.locatorText = c.locatorText.map(r)
            c.workspaceExhibitLabel = c.workspaceExhibitLabel.map(r)
            if var b = c.bibliographic {
                b.title = b.title.map(r)
                b.authors = b.authors.map(r)
                b.container = b.container.map(r)
                b.url = b.url.map(r)
                c.bibliographic = b
            }
            return c
        }
        var manifest = d.manifest
        manifest.workspaceTitle = manifest.workspaceTitle.map(r)
        manifest.reviewStatusSummary = manifest.reviewStatusSummary.map(r)
        manifest.knownLimitations = manifest.knownLimitations.map(r)
        manifest.citationMap = manifest.citationMap.map { e in var e = e; e.label = r(e.label); return e }
        return ExportableDocument(
            title: r(d.title), subtitle: d.subtitle.map(r), sections: sections, table: table,
            citations: citations, citationStyle: d.citationStyle, disclaimer: d.disclaimer.map(r),
            manifest: manifest)
    }
}
