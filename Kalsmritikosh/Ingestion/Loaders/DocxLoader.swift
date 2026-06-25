//
//  DocxLoader.swift
//  Kalsmritikosh
//
//  Real DOCX / ODT parser. DOCX is a ZIP with `word/document.xml` (Office
//  Open XML). ODT is a ZIP with `content.xml` (OpenDocument). We extract
//  the body text by stripping all XML tags — sufficient for entity /
//  event extraction; structural fidelity isn't needed at the KO layer.
//

import Foundation

public struct DocxLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.docx, .doc, .odt]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0

        switch type {
        case .docx:
            return try ingestOOXML(url: url, size: size)
        case .odt:
            return try ingestODT(url: url, size: size)
        case .doc:
            // Legacy binary .doc (Compound File Binary Format) isn't ZIP.
            // Genuine support needs an OLE2 parser; until then it remains
            // a metadata-only KO so the rest of the pipeline still sees it.
            return KnowledgeObject(
                sourceFile: url,
                sourceType: .doc,
                content: "Legacy Word .doc binary; OLE2 parsing pending.",
                metadata: [
                    "filename": AnyCodable(.string(url.lastPathComponent)),
                    "binarySize": AnyCodable(.int(size)),
                    "loaderStub": AnyCodable(.string("doc-legacy"))
                ],
                confidence: .low
            )
        default:
            throw IngestorError.unsupportedType(type)
        }
    }

    private func ingestOOXML(url: URL, size: Int64) throws -> KnowledgeObject {
        let zip = try ZIPReader(url: url)
        let entries = try zip.entries()
        // Order matters: header / footer / body / endnotes / footnotes.
        let candidates = entries.map(\.name).filter { name in
            name == "word/document.xml" ||
            name.hasPrefix("word/header") || name.hasPrefix("word/footer") ||
            name == "word/endnotes.xml" || name == "word/footnotes.xml"
        }.sorted { docxOrder($0) < docxOrder($1) }

        guard !candidates.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "no word/document.xml in DOCX")
        }

        var pieces: [String] = []
        for name in candidates {
            let xml = try zip.read(name)
            pieces.append(extractText(from: xml))
        }
        let content = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: .docx,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("docx-ooxml")),
                "binarySize": AnyCodable(.int(size)),
                "partsParsed": AnyCodable(.int(Int64(candidates.count)))
            ]
        )
    }

    private func ingestODT(url: URL, size: Int64) throws -> KnowledgeObject {
        let zip = try ZIPReader(url: url)
        let xml = try zip.read("content.xml")
        let content = extractText(from: xml)
        if content.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .odt,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("odt-opendocument")),
                "binarySize": AnyCodable(.int(size))
            ]
        )
    }

    private func docxOrder(_ name: String) -> Int {
        if name.hasPrefix("word/header") { return 0 }
        if name == "word/document.xml" { return 1 }
        if name == "word/footnotes.xml" { return 2 }
        if name == "word/endnotes.xml" { return 3 }
        if name.hasPrefix("word/footer") { return 4 }
        return 5
    }

    // MARK: - XML-to-text (structured)

    /// Element-aware extraction. Inspired by mammoth/python-docx: walks
    /// the OOXML tree instead of stripping all tags into a blob. Emits
    /// markdown so the downstream chunker / entity-extractor sees real
    /// paragraph and heading boundaries.
    ///
    /// Recognises:
    ///   - `<w:p>` paragraphs (separated by blank lines)
    ///   - `<w:pStyle w:val="Heading1"/>` ... `Heading6` (rendered with
    ///     leading `# `, `## `, ...)
    ///   - `<w:r>` runs inside paragraphs (inline text)
    ///   - `<w:t>` text leaves (the actual characters)
    ///   - `<w:br>` and `<w:tab>` (inline whitespace)
    ///   - `<w:tbl>`/`<w:tr>`/`<w:tc>` tables (rendered as markdown rows)
    ///   - `<w:numPr>` (list item — rendered as `- ` prefix)
    ///
    /// Falls back to the original tag-stripper on parse failure so we
    /// never regress.
    private func extractText(from data: Data) -> String {
        let xml = String(decoding: data, as: UTF8.self)
        if let structured = Self.structuredExtract(data: data), !structured.isEmpty {
            return structured
        }
        return Self.stripTags(xml)
    }

    static func structuredExtract(data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = OOXMLStructuredDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.render()
    }

    /// Strips XML tags and entity-decodes the result. We intentionally
    /// keep block-level tags as paragraph breaks so sentence tokenization
    /// downstream stays sane.
    nonisolated static func stripTags(_ xml: String) -> String {
        var out = ""
        var insideTag = false
        var lastWasSpace = false
        for ch in xml {
            if ch == "<" {
                insideTag = true
            } else if ch == ">" {
                insideTag = false
                // Treat block tag closes as a soft space so adjacent
                // <w:p>One</w:p><w:p>Two</w:p> doesn't merge.
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else if !insideTag {
                if ch.isWhitespace {
                    if !lastWasSpace {
                        out.append(" ")
                        lastWasSpace = true
                    }
                } else {
                    out.append(ch)
                    lastWasSpace = false
                }
            }
        }
        return entityDecode(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func entityDecode(_ s: String) -> String {
        var t = s
        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (from, to) in replacements {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return decodeNumericEntities(t)
    }

    /// Replaces `&#65;` and `&#x41;` style references with their unicode
    /// scalars. Office docs occasionally emit these for accented chars.
    nonisolated static func decodeNumericEntities(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "&",
               let semi = input[i...].firstIndex(of: ";"),
               input.distance(from: i, to: semi) <= 8,
               input[input.index(after: i)] == "#" {
                let body = input[input.index(i, offsetBy: 2)..<semi]
                let isHex = body.first == "x" || body.first == "X"
                let digits = isHex ? body.dropFirst() : body
                if let value = isHex
                    ? UInt32(digits, radix: 16)
                    : UInt32(digits, radix: 10),
                   let scalar = Unicode.Scalar(value) {
                    output.append(Character(scalar))
                    i = input.index(after: semi)
                    continue
                }
            }
            output.append(input[i])
            i = input.index(after: i)
        }
        return output
    }
}

// MARK: - OOXMLStructuredDelegate

/// XMLParser delegate that walks `word/document.xml` (and headers /
/// footers, same vocabulary) and emits markdown with paragraph + heading
/// + list + table boundaries preserved. Inspired by mammoth's mapping
/// philosophy: convert Word's structure to markdown so the chunker sees
/// real boundaries instead of one space-flattened blob.
private final class OOXMLStructuredDelegate: NSObject, XMLParserDelegate {
    private var output: [String] = []
    private var currentParagraph = ""
    private var currentHeadingLevel: Int = 0
    private var isListItem = false
    private var currentTableRows: [[String]] = []
    private var currentTableRow: [String] = []
    private var currentCell = ""
    private var depth = ElementStack()

    // Accumulates the text of <w:t> leaves. Multiple runs in one paragraph
    // all flow into `currentParagraph`.
    private var capturingText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let local = ElementStack.local(elementName)
        depth.push(local)
        switch local {
        case "p":
            currentParagraph = ""
            currentHeadingLevel = 0
            isListItem = false
        case "pStyle":
            // <w:pStyle w:val="Heading1"/> — pick up the val attr.
            if let val = attributeDict["w:val"] ?? attributeDict["val"] {
                if val.hasPrefix("Heading") {
                    let n = Int(val.dropFirst("Heading".count)) ?? 1
                    currentHeadingLevel = max(1, min(6, n))
                }
            }
        case "numPr":
            isListItem = true
        case "t":
            capturingText = true
        case "br":
            currentParagraph.append("\n")
        case "tab":
            currentParagraph.append("\t")
        case "tbl":
            currentTableRows = []
        case "tr":
            currentTableRow = []
        case "tc":
            currentCell = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturingText else { return }
        // Cell content goes to the cell buffer; otherwise to the paragraph.
        if depth.contains("tc") {
            currentCell.append(string)
        } else {
            currentParagraph.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = ElementStack.local(elementName)
        switch local {
        case "t":
            capturingText = false
        case "p":
            let trimmed = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if currentHeadingLevel > 0 {
                    output.append(String(repeating: "#", count: currentHeadingLevel) + " " + trimmed)
                } else if isListItem {
                    output.append("- " + trimmed)
                } else {
                    output.append(trimmed)
                }
            }
            currentParagraph = ""
            currentHeadingLevel = 0
            isListItem = false
        case "tc":
            currentTableRow.append(currentCell.trimmingCharacters(in: .whitespacesAndNewlines))
            currentCell = ""
        case "tr":
            currentTableRows.append(currentTableRow)
            currentTableRow = []
        case "tbl":
            if !currentTableRows.isEmpty {
                // Markdown table — header row, alignment row, then data.
                let widest = currentTableRows.map(\.count).max() ?? 0
                let normalized = currentTableRows.map { row in
                    row + Array(repeating: "", count: max(0, widest - row.count))
                }
                let header = normalized[0]
                output.append("| " + header.joined(separator: " | ") + " |")
                output.append("|" + String(repeating: " --- |", count: widest))
                for row in normalized.dropFirst() {
                    output.append("| " + row.joined(separator: " | ") + " |")
                }
            }
            currentTableRows = []
        default:
            break
        }
        depth.pop()
    }

    func render() -> String {
        output.joined(separator: "\n\n")
    }

    /// Tiny stack of local element names (namespace prefix stripped) so
    /// we can ask "are we currently inside a <tc>?" cheaply.
    private struct ElementStack {
        private var names: [String] = []
        mutating func push(_ s: String) { names.append(s) }
        mutating func pop() { _ = names.popLast() }
        func contains(_ s: String) -> Bool { names.contains(s) }
        static func local(_ qualified: String) -> String {
            if let i = qualified.firstIndex(of: ":") {
                return String(qualified[qualified.index(after: i)...])
            }
            return qualified
        }
    }
}
