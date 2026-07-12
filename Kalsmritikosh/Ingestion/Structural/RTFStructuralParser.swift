//
//  RTFStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — RTF into structured EvidenceBlocks. Decodes the RTF to attributed text
//  via NSAttributedString (same peel the legacy TextLoader uses), then splits
//  the plain text into paragraph blocks on paragraph boundaries, each with a
//  character-range locator into the decoded text so a citation reopens the
//  exact span. Deterministic, zero-LLM. Heading detection from RTF font runs is
//  a later refinement; prose paragraphs are the reliable unit today.
//

import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

public struct RTFStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.rtf] }
    public nonisolated var parserName: String { "rtf-attributed" }
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

        let plain = Self.decodeToPlainText(data)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .rtf, mimeType: "application/rtf",
                contentHash: hash, blocks: [], extractionStatus: .empty
            )
        }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        for (i, span) in Self.paragraphSpans(plain).enumerated() {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: .paragraph, rawText: span.text,
                locator: SourceLocator(characterRange: span.range, paragraphIndex: i),
                extractionMethod: .native
            ))
            ordinal += 1
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .rtf, mimeType: "application/rtf",
            contentHash: hash, blocks: blocks,
            extractionStatus: blocks.isEmpty ? .empty : .complete
        )
    }

    // MARK: - Decoding + paragraph segmentation (pure)

    static func decodeToPlainText(_ data: Data) -> String {
        #if canImport(AppKit)
        if let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attr.string
        }
        #endif
        // Fallback: treat as UTF-8/Latin-1 text (still tracked, coarse).
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    struct ParagraphSpan { let text: String; let range: Range<Int> }

    /// Split decoded text into paragraphs on newline boundaries, returning each
    /// paragraph's text and its character range in the decoded string. Blank
    /// lines are skipped but still advance the offset so ranges stay accurate.
    static func paragraphSpans(_ text: String) -> [ParagraphSpan] {
        var spans: [ParagraphSpan] = []
        var offset = 0
        // Preserve range accuracy by walking the original lines including their
        // separators (\n counts as one character toward the offset).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            let lineLen = line.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Range covers the untrimmed line; leading-space trim doesn't
                // move the anchor much and keeps reopen simple.
                spans.append(ParagraphSpan(text: trimmed, range: offset..<(offset + lineLen)))
            }
            offset += lineLen
            if idx < lines.count - 1 { offset += 1 }  // the '\n' separator
        }
        return spans
    }
}
