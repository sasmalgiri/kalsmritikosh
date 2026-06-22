//
//  Cleaner.swift
//  Kalsmritikosh
//
//  Light-weight content normalization run after every loader: encoding
//  fix-ups, whitespace collapsing, language tagging, and a permissive
//  spam heuristic for inbound mail.
//

import Foundation
import NaturalLanguage
import CryptoKit

public struct Cleaner: Sendable {
    public nonisolated init() {}

    public nonisolated func clean(_ object: KnowledgeObject) -> KnowledgeObject {
        let normalized = collapseWhitespace(repairEncoding(object.content))
        let language = detectLanguage(normalized)
        let spamScore = spamProbability(normalized)
        let hash = contentHash(normalized)

        var meta = object.metadata
        if let language { meta["language"] = AnyCodable(.string(language)) }
        meta["spamScore"] = AnyCodable(.double(spamScore))
        meta["contentHash"] = AnyCodable(.string(hash))

        return KnowledgeObject(
            id: object.id,
            sourceFile: object.sourceFile,
            sourceType: object.sourceType,
            content: normalized,
            metadata: meta,
            entities: object.entities,
            events: object.events,
            relationships: object.relationships,
            summaries: object.summaries,
            confidence: object.confidence,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt
        )
    }

    private func repairEncoding(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FEFF}", with: "")
         .replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func collapseWhitespace(_ s: String) -> String {
        var result = ""
        var lastWasSpace = false
        var lastWasNewline = false
        var consecutiveNewlines = 0
        for ch in s {
            if ch == "\n" {
                consecutiveNewlines += 1
                lastWasSpace = false
                if consecutiveNewlines <= 2 {
                    result.append("\n")
                    lastWasNewline = true
                }
            } else if ch.isWhitespace {
                if !lastWasSpace && !lastWasNewline {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(ch)
                lastWasSpace = false
                lastWasNewline = false
                consecutiveNewlines = 0
            }
        }
        return result
    }

    private func detectLanguage(_ s: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(s.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }

    /// 0...1 — entirely heuristic, used only to lightly downweight messages
    /// that look like marketing or boilerplate. Never auto-removes content.
    private func spamProbability(_ s: String) -> Double {
        let lower = s.lowercased()
        let signals: [String] = [
            "unsubscribe", "click here", "limited time", "act now",
            "you have won", "viagra", "free trial", "100% guaranteed"
        ]
        var hits = 0
        for s in signals where lower.contains(s) { hits += 1 }
        return min(1.0, Double(hits) / Double(signals.count) * 1.5)
    }

    private func contentHash(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
