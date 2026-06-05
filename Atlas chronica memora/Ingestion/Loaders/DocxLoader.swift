//
//  DocxLoader.swift
//  Atlas chronica memora
//
//  Real DOCX / ODT parser. DOCX is a ZIP with `word/document.xml` (Office
//  Open XML). ODT is a ZIP with `content.xml` (OpenDocument). We extract
//  the body text by stripping all XML tags — sufficient for entity /
//  event extraction; structural fidelity isn't needed at the KO layer.
//

import Foundation

public struct DocxLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.docx, .doc, .odt]

    public init() {}

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

    // MARK: - XML-to-text (tag stripper)

    private func extractText(from data: Data) -> String {
        let xml = String(decoding: data, as: UTF8.self)
        return Self.stripTags(xml)
    }

    /// Strips XML tags and entity-decodes the result. We intentionally
    /// keep block-level tags as paragraph breaks so sentence tokenization
    /// downstream stays sane.
    static func stripTags(_ xml: String) -> String {
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

    private static func entityDecode(_ s: String) -> String {
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
    private static func decodeNumericEntities(_ input: String) -> String {
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
