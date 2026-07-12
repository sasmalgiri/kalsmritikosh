//
//  ODTStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — OpenDocument Text (.odt) into structured EvidenceBlocks in reading
//  order. Reads `content.xml` from the ZIP and walks `<office:text>` in document
//  order emitting typed blocks: `<text:h>` → sectionHeading (outline level →
//  running sectionPath), `<text:p>` → paragraph. Each block carries a
//  sectionPath + paragraphIndex locator. Replaces the legacy path that routed
//  ODT through DocxLoader and flattened it. Deterministic, zero-LLM.
//

import Foundation
import CryptoKit

public struct ODTStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.odt] }
    public nonisolated var parserName: String { "odt-opendocument" }
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

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("odt-\(UUID().uuidString).odt")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: text, locator: locator, extractionMethod: .native
            ))
            ordinal += 1
        }

        do {
            let zip = try ZIPReader(url: tmp)
            let xml = String(decoding: try zip.read("content.xml"), as: UTF8.self)
            let elements = Self.textElements(xml)
            guard !elements.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [], .empty)
            }
            var sectionStack: [String] = []
            var paragraphIndex = 0
            for el in elements {
                if let level = el.outlineLevel {
                    if sectionStack.count >= level { sectionStack.removeSubrange((level - 1)..<sectionStack.count) }
                    while sectionStack.count < level - 1 { sectionStack.append("") }
                    sectionStack.append(el.text)
                    add(.sectionHeading, el.text,
                        SourceLocator(sectionPath: sectionStack.filter { !$0.isEmpty }))
                } else {
                    let path = sectionStack.filter { !$0.isEmpty }
                    add(.paragraph, el.text,
                        SourceLocator(sectionPath: path.isEmpty ? nil : path, paragraphIndex: paragraphIndex))
                    paragraphIndex += 1
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "odt.unreadable", message: "\(error)")
            ], .corrupt)
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .odt,
            mimeType: "application/vnd.oasis.opendocument.text",
            contentHash: hash, blocks: blocks,
            extractionStatus: blocks.isEmpty ? .empty : .complete
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .odt, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    // MARK: - OpenDocument content.xml parsing (pure)

    struct TextElement {
        let isHeading: Bool
        let outlineLevel: Int?  // nil for paragraphs
        let text: String
    }

    /// `<text:h>` and `<text:p>` elements in reading order. Headings carry their
    /// `text:outline-level`; self-closing empty elements are skipped. Scoped to
    /// `<office:text>` when present to skip styles/meta.
    static func textElements(_ xml: String) -> [TextElement] {
        var scope = xml
        if let open = xml.range(of: "<office:text"),
           let head = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
           let close = xml.range(of: "</office:text>", range: head.upperBound..<xml.endIndex) {
            scope = String(xml[head.upperBound..<close.lowerBound])
        }
        var out: [TextElement] = []
        var cursor = scope.startIndex
        while cursor < scope.endIndex {
            // Nearest opening of <text:h or <text:p (real tag boundary).
            var best: (tag: String, open: String.Index, head: Range<String.Index>)?
            for tag in ["text:h", "text:p"] {
                guard let o = scope.range(of: "<\(tag)", range: cursor..<scope.endIndex),
                      let head = scope.range(of: ">", range: o.upperBound..<scope.endIndex) else { continue }
                let after = scope[o.upperBound]
                guard after == " " || after == ">" || after == "/" || after == "\n" || after == "\t" else { continue }
                if best == nil || o.lowerBound < best!.open { best = (tag, o.lowerBound, head) }
            }
            guard let b = best else { break }
            // Self-closing element (<text:p/>) — no content, skip past it.
            let gt = b.head.lowerBound
            if gt > scope.startIndex, scope[scope.index(before: gt)] == "/" {
                cursor = b.head.upperBound
                continue
            }
            guard let close = scope.range(of: "</\(b.tag)>", range: b.head.upperBound..<scope.endIndex) else { break }
            let body = String(scope[b.head.upperBound..<close.lowerBound])
            let text = DocxLoader.stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if b.tag == "text:h" {
                    let openTag = String(scope[b.open..<b.head.upperBound])
                    let level = Self.attrInt(openTag, "text:outline-level") ?? 1
                    out.append(TextElement(isHeading: true, outlineLevel: max(1, level), text: text))
                } else {
                    out.append(TextElement(isHeading: false, outlineLevel: nil, text: text))
                }
            }
            cursor = close.upperBound
        }
        return out
    }

    private static func attrInt(_ tag: String, _ name: String) -> Int? {
        guard let r = tag.range(of: "\(name)=\""),
              let end = tag.range(of: "\"", range: r.upperBound..<tag.endIndex) else { return nil }
        return Int(tag[r.upperBound..<end.lowerBound])
    }
}
