//
//  Chunker.swift
//  Kalsmritikosh
//
//  Boundary-aware chunker. Splits a KnowledgeObject's content into
//  bounded Chunks for embeddings + LLM context, but respects STRUCTURAL
//  boundaries first (headings, paragraphs) and only falls back to
//  sentence-level splits when a single block exceeds the budget. The
//  prior implementation was sentence-only with a hard char budget,
//  which meant a 2000-char paragraph could end up split mid-paragraph
//  into two chunks that lost their topical coherence — bad for both
//  embedding similarity AND citation snippets.
//
//  Strategy (in order):
//
//    1. Split content into BLOCKS:
//       - lines starting with `#` (markdown heading) → standalone block,
//         and ALWAYS terminate the running chunk before emitting them
//       - lines matching `Subject:` / `From:` / `To:` / `Date:`
//         (email headers) → standalone short blocks
//       - paragraphs separated by blank lines
//
//    2. Pack blocks into chunks up to `targetCharacterCount`:
//       - if a single block exceeds the budget, fall back to sentence
//         splits within just that block
//       - otherwise group small adjacent blocks until the budget fills
//
//  Output Chunk model is unchanged — same char-range, ordinal, page
//  number contract so SourceViewer + citation highlighting still work.
//

import Foundation
import NaturalLanguage

public struct Chunker: Sendable {
    public let targetCharacterCount: Int
    /// Below this size, an emitted chunk gets merged into the next
    /// block instead of standing alone. Prevents micro-chunks
    /// (single-line headings) from being treated as standalone
    /// retrieval candidates.
    public let minChunkCharacterCount: Int

    public nonisolated init(
        targetCharacterCount: Int = 1200,
        minChunkCharacterCount: Int = 80
    ) {
        self.targetCharacterCount = targetCharacterCount
        self.minChunkCharacterCount = minChunkCharacterCount
    }

    public nonisolated func chunk(
        objectID: KnowledgeObject.ID,
        content: String,
        pageBreaks: [Int] = []
    ) -> [Chunk] {
        guard !content.isEmpty else { return [] }

        let blocks = splitIntoBlocks(content)
        var chunks: [Chunk] = []
        var ordinal = 0

        var bufferStart: Int?
        var bufferEnd: Int = 0
        var bufferText: String = ""

        func flush() {
            guard let start = bufferStart, bufferEnd > start, !bufferText.isEmpty else {
                bufferStart = nil
                bufferEnd = 0
                bufferText = ""
                return
            }
            chunks.append(Chunk(
                objectID: objectID,
                ordinal: ordinal,
                text: bufferText,
                characterRange: start..<bufferEnd,
                pageNumber: nearestPage(for: start, breaks: pageBreaks)
            ))
            ordinal += 1
            bufferStart = nil
            bufferEnd = 0
            bufferText = ""
        }

        for block in blocks {
            // Strong-boundary block (heading) — always flush before
            // emitting so a heading starts its own chunk group.
            if block.isStrongBoundary {
                flush()
            }

            // Block exceeds the budget on its own — split by
            // sentences and emit each sub-chunk separately.
            if block.length > targetCharacterCount {
                flush()
                for sub in sentenceSplit(content, range: block.start..<block.end) {
                    chunks.append(Chunk(
                        objectID: objectID,
                        ordinal: ordinal,
                        text: sub.text,
                        characterRange: sub.start..<sub.end,
                        pageNumber: nearestPage(for: sub.start, breaks: pageBreaks)
                    ))
                    ordinal += 1
                }
                continue
            }

            // Would adding this block overflow? Flush first.
            let currentLen = bufferStart != nil ? (bufferEnd - bufferStart!) : 0
            if currentLen + block.length > targetCharacterCount && currentLen >= minChunkCharacterCount {
                flush()
            }

            // Append the block.
            if bufferStart == nil {
                bufferStart = block.start
            }
            bufferEnd = block.end
            if !bufferText.isEmpty { bufferText += "\n\n" }
            bufferText += block.text
        }

        flush()
        return chunks
    }

    // MARK: - Block detection

    private struct Block {
        let start: Int
        let end: Int
        let text: String
        let isStrongBoundary: Bool
        var length: Int { end - start }
    }

    private nonisolated func splitIntoBlocks(_ content: String) -> [Block] {
        var blocks: [Block] = []
        var index = content.startIndex
        let utf16Start = content.utf16.startIndex
        var paragraphStartUTF16: Int? = nil
        var paragraphLines: [String] = []

        // Split on lines so we can detect heading + blank-line
        // structure without paying for a full regex pass.
        let lines = content.components(separatedBy: "\n")
        var cursor = 0 // utf16 offset

        func flushParagraph() {
            guard let start = paragraphStartUTF16, !paragraphLines.isEmpty else {
                paragraphStartUTF16 = nil
                paragraphLines.removeAll()
                return
            }
            let joined = paragraphLines.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let end = start + joined.utf16.count
                blocks.append(Block(start: start, end: end, text: joined, isStrongBoundary: false))
            }
            paragraphStartUTF16 = nil
            paragraphLines.removeAll()
        }

        for (i, line) in lines.enumerated() {
            let lineUTF16Count = line.utf16.count
            let lineStart = cursor
            // +1 for the "\n" we split on, except last line
            let next = i < lines.count - 1 ? cursor + lineUTF16Count + 1 : cursor + lineUTF16Count
            defer { cursor = next; _ = utf16Start; _ = index }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — paragraph boundary
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Markdown heading — always its own block, marked as strong
            if isHeading(trimmed) || isEmailHeader(trimmed) {
                flushParagraph()
                blocks.append(Block(
                    start: lineStart,
                    end: lineStart + lineUTF16Count,
                    text: line,
                    isStrongBoundary: true
                ))
                continue
            }

            // Regular content line — accumulate into the running paragraph
            if paragraphStartUTF16 == nil {
                paragraphStartUTF16 = lineStart
            }
            paragraphLines.append(line)
        }

        flushParagraph()
        return blocks
    }

    private nonisolated func isHeading(_ line: String) -> Bool {
        // Markdown ATX heading
        if line.hasPrefix("#") {
            // Must have content after the hashes
            return line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil
        }
        return false
    }

    private nonisolated func isEmailHeader(_ line: String) -> Bool {
        // Common email-style header lines
        return line.range(
            of: #"^(Subject|From|To|Cc|Bcc|Date|Reply-To|Message-Id):\s"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Sentence fallback

    private struct SentenceChunk {
        let text: String
        let start: Int
        let end: Int
    }

    /// Sentence-aware split inside a block that's too big for the
    /// budget. Uses NLTokenizer for the sentence boundaries; packs
    /// sentences into char-budget chunks.
    private nonisolated func sentenceSplit(
        _ content: String,
        range: Range<Int>
    ) -> [SentenceChunk] {
        // Resolve UTF-16 range to String indices for the tokenizer.
        let utf16 = content.utf16
        guard let from = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
              let to = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex),
              let stringFrom = from.samePosition(in: content),
              let stringTo = to.samePosition(in: content),
              stringFrom < stringTo else {
            return []
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = content

        var out: [SentenceChunk] = []
        var bufferStart: Int = range.lowerBound
        var bufferLen: Int = 0

        tokenizer.enumerateTokens(in: stringFrom..<stringTo) { tokenRange, _ in
            let lower = utf16.distance(from: utf16.startIndex, to: tokenRange.lowerBound)
            let upper = utf16.distance(from: utf16.startIndex, to: tokenRange.upperBound)
            let length = upper - lower

            if bufferLen == 0 {
                bufferStart = lower
                bufferLen = length
            } else if bufferLen + length > targetCharacterCount {
                let end = bufferStart + bufferLen
                out.append(SentenceChunk(
                    text: substring(content, lower: bufferStart, upper: end),
                    start: bufferStart,
                    end: end
                ))
                bufferStart = lower
                bufferLen = length
            } else {
                bufferLen += length
            }
            return true
        }

        if bufferLen > 0 {
            let end = bufferStart + bufferLen
            out.append(SentenceChunk(
                text: substring(content, lower: bufferStart, upper: end),
                start: bufferStart,
                end: end
            ))
        }

        return out
    }

    // MARK: - Helpers

    private nonisolated func substring(_ s: String, lower: Int, upper: Int) -> String {
        let from = s.utf16.index(s.utf16.startIndex, offsetBy: max(0, lower))
        let to = s.utf16.index(s.utf16.startIndex, offsetBy: min(s.utf16.count, upper))
        return String(String.UnicodeScalarView(s.utf16[from..<to].compactMap(Unicode.Scalar.init)))
    }

    private nonisolated func nearestPage(for offset: Int, breaks: [Int]) -> Int? {
        guard !breaks.isEmpty else { return nil }
        var page = 1
        for b in breaks { if offset >= b { page += 1 } else { break } }
        return page
    }
}
