//
//  DocxStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — DOCX into typed EvidenceBlocks. Walks the OOXML parts in order
//  (header → body → footnotes → endnotes → footer) and emits headings (with a
//  live section path), list items, paragraphs and tables as distinct blocks —
//  header/footer parts as boilerplate. Reuses the ZIP reader + entity decoding
//  from the DOCX loader; deterministic, no LLM.
//

import Foundation
import CryptoKit

public struct DocxStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.docx] }
    public nonisolated var parserName: String { "docx-ooxml" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // Read the DOCX ZIP from the in-memory bytes.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-\(UUID().uuidString).docx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var warnings: [ParserWarning] = []
        var rawBlocks: [(kind: EvidenceBlockKind, text: String, section: [String], parent: UUID?, boilerplate: Bool)] = []

        do {
            let zip = try ZIPReader(url: tmp)
            let entries = try zip.entries()
            let parts = entries.map(\.name).filter { name in
                name == "word/document.xml" ||
                name.hasPrefix("word/header") || name.hasPrefix("word/footer") ||
                name == "word/endnotes.xml" || name == "word/footnotes.xml"
            }.sorted { Self.partOrder($0) < Self.partOrder($1) }

            guard !parts.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "docx.no_document",
                                  message: "No word/document.xml in DOCX.")
                ], .corrupt)
            }

            for part in parts {
                let partKind = Self.partKind(part)
                let xml = try zip.read(part)
                let delegate = OOXMLBlockDelegate(partKind: partKind)
                let parser = XMLParser(data: xml)
                parser.delegate = delegate
                if parser.parse() {
                    rawBlocks.append(contentsOf: delegate.blocks)
                } else {
                    warnings.append(ParserWarning(code: "docx.part_parse_failed",
                                                  message: "Failed to parse \(part).", context: part))
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "docx.unreadable",
                              message: "\(error)")
            ], .corrupt)
        }

        // Assemble EvidenceBlocks with ordinals + confidence (native = 1.0).
        var blocks: [EvidenceBlock] = []
        var sawTitle = false
        for (i, rb) in rawBlocks.enumerated() {
            var kind = rb.kind
            if kind == .documentTitle {
                if sawTitle { kind = .sectionHeading } else { sawTitle = true }
            }
            blocks.append(EvidenceBlock(
                documentID: documentID,
                sourceVersionID: sourceVersionID,
                ordinal: i,
                kind: kind,
                rawText: rb.text,
                locator: SourceLocator(sectionPath: rb.section.isEmpty ? nil : rb.section,
                                       paragraphIndex: i),
                extractionMethod: .native,
                extractionConfidence: 1.0
            ))
        }

        let status: ExtractionStatus = blocks.isEmpty ? .empty : (warnings.isEmpty ? .complete : .partial)
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .docx,
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .docx, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    static func partOrder(_ name: String) -> Int {
        if name.hasPrefix("word/header") { return 0 }
        if name == "word/document.xml" { return 1 }
        if name == "word/footnotes.xml" { return 2 }
        if name == "word/endnotes.xml" { return 3 }
        if name.hasPrefix("word/footer") { return 4 }
        return 5
    }

    static func partKind(_ name: String) -> OOXMLBlockDelegate.PartKind {
        if name.hasPrefix("word/header") { return .header }
        if name.hasPrefix("word/footer") { return .footer }
        if name == "word/footnotes.xml" { return .footnotes }
        if name == "word/endnotes.xml" { return .endnotes }
        return .body
    }
}

// MARK: - OOXMLBlockDelegate

/// XMLParser delegate that emits TYPED evidence blocks (not markdown) from a
/// DOCX part, tracking heading depth as a live section path.
final class OOXMLBlockDelegate: NSObject, XMLParserDelegate {
    enum PartKind { case body, header, footer, footnotes, endnotes }

    private let partKind: PartKind
    private(set) var blocks: [(kind: EvidenceBlockKind, text: String, section: [String], parent: UUID?, boilerplate: Bool)] = []

    private var paragraph = ""
    private var headingLevel = 0
    private var isListItem = false
    private var section: [String] = []
    private var capturing = false
    private var stack: [String] = []
    private var tableRows: [[String]] = []
    private var tableRow: [String] = []
    private var cell = ""

    init(partKind: PartKind) { self.partKind = partKind }

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
        let local = Self.local(e)
        stack.append(local)
        switch local {
        case "p": paragraph = ""; headingLevel = 0; isListItem = false
        case "pStyle":
            if let val = a["w:val"] ?? a["val"], val.hasPrefix("Heading") {
                headingLevel = max(1, min(6, Int(val.dropFirst("Heading".count)) ?? 1))
            }
        case "numPr": isListItem = true
        case "t": capturing = true
        case "br": paragraph.append("\n")
        case "tab": paragraph.append("\t")
        case "tbl": tableRows = []
        case "tr": tableRow = []
        case "tc": cell = ""
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        guard capturing else { return }
        if stack.contains("tc") { cell.append(s) } else { paragraph.append(s) }
    }

    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let local = Self.local(e)
        switch local {
        case "t": capturing = false
        case "p":
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { emitParagraph(text) }
            paragraph = ""; headingLevel = 0; isListItem = false
        case "tc": tableRow.append(cell.trimmingCharacters(in: .whitespacesAndNewlines)); cell = ""
        case "tr": tableRows.append(tableRow); tableRow = []
        case "tbl": emitTable()
        default: break
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    private func emitParagraph(_ text: String) {
        switch partKind {
        case .header: blocks.append((.pageHeader, text, section, nil, true)); return
        case .footer: blocks.append((.pageFooter, text, section, nil, true)); return
        case .footnotes: blocks.append((.footnote, text, section, nil, false)); return
        case .endnotes: blocks.append((.endnote, text, section, nil, false)); return
        case .body: break
        }
        if headingLevel > 0 {
            // Maintain a heading-depth section path.
            if section.count >= headingLevel { section.removeSubrange((headingLevel - 1)..<section.count) }
            while section.count < headingLevel - 1 { section.append("") }
            section.append(text)
            let kind: EvidenceBlockKind = headingLevel == 1 ? .documentTitle : .sectionHeading
            blocks.append((kind, text, section, nil, false))
        } else if isListItem {
            blocks.append((.listItem, text, section, nil, false))
        } else {
            blocks.append((.paragraph, text, section, nil, false))
        }
    }

    private func emitTable() {
        guard !tableRows.isEmpty else { return }
        let rendered = tableRows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
        let tableID = UUID()
        blocks.append((.table, rendered, section, nil, false))
        for row in tableRows where !row.allSatisfy({ $0.isEmpty }) {
            blocks.append((.tableRow, row.joined(separator: " | "), section, tableID, false))
        }
        tableRows = []
    }

    static func local(_ qualified: String) -> String {
        if let i = qualified.firstIndex(of: ":") { return String(qualified[qualified.index(after: i)...]) }
        return qualified
    }
}
