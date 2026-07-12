//
//  PlainTextStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — first real StructuralParser: plain text + Markdown into typed
//  EvidenceBlocks. Recognizes titles/headings (with section path), list items,
//  block quotes, fenced code, and blank-line-delimited paragraphs, each with a
//  character-range SourceLocator into the original text. No LLM, deterministic.
//

import Foundation
import CryptoKit

public struct PlainTextStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.txt, .markdown] }
    public nonisolated var parserName: String { "plaintext" }
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
        let text = String(decoding: data, as: UTF8.self)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []
        var ordinal = 0
        var sectionPath: [String] = []
        var sawTitle = false

        func addBlock(_ kind: EvidenceBlockKind, _ raw: String, range: Range<Int>) {
            blocks.append(EvidenceBlock(
                documentID: documentID,
                sourceVersionID: sourceVersionID,
                ordinal: ordinal,
                kind: kind,
                rawText: raw,
                locator: SourceLocator(
                    characterRange: range,
                    sectionPath: sectionPath.isEmpty ? nil : sectionPath
                )
            ))
            ordinal += 1
        }

        let isMarkdown = (type == .markdown)
        // Iterate lines while tracking character offsets into `text`.
        var offset = 0
        var paragraph = ""
        var paragraphStart = 0
        var inCodeFence = false
        var codeBuffer = ""
        var codeStart = 0

        func flushParagraph() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addBlock(.paragraph, paragraph, range: paragraphStart..<(paragraphStart + paragraph.utf8.count))
            }
            paragraph = ""
        }

        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineLen = line.utf8.count
            let lineStart = offset
            offset += lineLen + (i < lines.count - 1 ? 1 : 0)   // + newline
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks (Markdown).
            if isMarkdown, stripped.hasPrefix("```") {
                if inCodeFence {
                    addBlock(.codeBlock, codeBuffer, range: codeStart..<lineStart)
                    codeBuffer = ""
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                    codeStart = lineStart
                }
                continue
            }
            if inCodeFence {
                codeBuffer += (codeBuffer.isEmpty ? "" : "\n") + line
                continue
            }

            // Blank line → paragraph boundary.
            if stripped.isEmpty { flushParagraph(); continue }

            if isMarkdown {
                // Headings: #, ##, …
                if let hashes = Self.headingLevel(stripped) {
                    flushParagraph()
                    let titleText = String(stripped.drop(while: { $0 == "#" || $0 == " " }))
                    let kind: EvidenceBlockKind = (!sawTitle && hashes == 1) ? .documentTitle : .sectionHeading
                    if kind == .documentTitle { sawTitle = true }
                    // Maintain a section path by heading depth.
                    if sectionPath.count >= hashes { sectionPath.removeSubrange((hashes - 1)..<sectionPath.count) }
                    while sectionPath.count < hashes - 1 { sectionPath.append("") }
                    sectionPath.append(titleText)
                    addBlock(kind, titleText, range: lineStart..<(lineStart + lineLen))
                    continue
                }
                // Block quote.
                if stripped.hasPrefix(">") {
                    flushParagraph()
                    addBlock(.quote, String(stripped.dropFirst()).trimmingCharacters(in: .whitespaces),
                             range: lineStart..<(lineStart + lineLen))
                    continue
                }
                // List item.
                if Self.isListItem(stripped) {
                    flushParagraph()
                    addBlock(.listItem, stripped, range: lineStart..<(lineStart + lineLen))
                    continue
                }
            }

            // Accumulate into the current paragraph.
            if paragraph.isEmpty { paragraphStart = lineStart }
            paragraph += (paragraph.isEmpty ? "" : "\n") + line
        }
        if inCodeFence, !codeBuffer.isEmpty {
            addBlock(.codeBlock, codeBuffer, range: codeStart..<offset)
            warnings.append(ParserWarning(code: "markdown.unclosed_code_fence",
                                          message: "Code fence was not closed before end of file."))
        }
        flushParagraph()

        let status: ExtractionStatus = blocks.isEmpty ? .empty : .complete
        return ParsedDocument(
            id: documentID,
            logicalSourceID: logicalSourceID,
            sourceVersionID: sourceVersionID,
            filename: filename,
            detectedType: type,
            mimeType: type == .markdown ? "text/markdown" : "text/plain",
            contentHash: hash,
            blocks: blocks,
            warnings: warnings,
            extractionStatus: status
        )
    }

    // MARK: - Markdown helpers (pure)

    /// Heading level 1…6 for a line starting with `#`s, else nil.
    static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        // A heading needs a space or end after the hashes ("#foo" is not one).
        let after = line.dropFirst(hashes)
        return (after.isEmpty || after.first == " ") ? hashes : nil
    }

    static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        // Ordered: "1. ", "12) "
        let prefix = line.prefix(while: { $0.isNumber })
        if !prefix.isEmpty {
            let rest = line.dropFirst(prefix.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        return false
    }
}
