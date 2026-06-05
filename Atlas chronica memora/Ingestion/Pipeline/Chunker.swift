//
//  Chunker.swift
//  Atlas chronica memora
//
//  Splits KnowledgeObject.content into bounded Chunks sized for both
//  embeddings and LLM context windows. Sentence-aware via NLTokenizer
//  so we don't cut mid-thought.
//

import Foundation
import NaturalLanguage

public struct Chunker: Sendable {
    public let targetCharacterCount: Int

    public init(targetCharacterCount: Int = 1200) {
        self.targetCharacterCount = targetCharacterCount
    }

    public func chunk(
        objectID: KnowledgeObject.ID,
        content: String,
        pageBreaks: [Int] = []
    ) -> [Chunk] {
        guard !content.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = content

        var chunks: [Chunk] = []
        var ordinal = 0
        var bufferStart = 0
        var bufferLength = 0

        tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            let lower = content.utf16.distance(from: content.startIndex, to: range.lowerBound)
            let upper = content.utf16.distance(from: content.startIndex, to: range.upperBound)
            let length = upper - lower

            if bufferLength == 0 {
                bufferStart = lower
                bufferLength = length
            } else if bufferLength + length > targetCharacterCount {
                let end = bufferStart + bufferLength
                let text = substring(content, lower: bufferStart, upper: end)
                chunks.append(.init(
                    objectID: objectID,
                    ordinal: ordinal,
                    text: text,
                    characterRange: bufferStart..<end,
                    pageNumber: nearestPage(for: bufferStart, breaks: pageBreaks)
                ))
                ordinal += 1
                bufferStart = lower
                bufferLength = length
            } else {
                bufferLength += length
            }
            return true
        }

        if bufferLength > 0 {
            let end = bufferStart + bufferLength
            let text = substring(content, lower: bufferStart, upper: end)
            chunks.append(.init(
                objectID: objectID,
                ordinal: ordinal,
                text: text,
                characterRange: bufferStart..<end,
                pageNumber: nearestPage(for: bufferStart, breaks: pageBreaks)
            ))
        }

        return chunks
    }

    private func substring(_ s: String, lower: Int, upper: Int) -> String {
        let from = s.utf16.index(s.utf16.startIndex, offsetBy: max(0, lower))
        let to = s.utf16.index(s.utf16.startIndex, offsetBy: min(s.utf16.count, upper))
        return String(String.UnicodeScalarView(s.utf16[from..<to].compactMap(Unicode.Scalar.init)))
    }

    private func nearestPage(for offset: Int, breaks: [Int]) -> Int? {
        guard !breaks.isEmpty else { return nil }
        var page = 1
        for b in breaks { if offset >= b { page += 1 } else { break } }
        return page
    }
}
