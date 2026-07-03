//
//  TokenBudget.swift
//  Kalsmritikosh
//
//  Small helpers for fitting work into the Apple on-device model's FIXED
//  4,096-token context window. The window can't be enlarged, so the only
//  lever is chunking: split input into pieces that fit, process each in its
//  own session (they can run in parallel), then combine. Token counts are
//  approximated from characters (~4 chars/token for Latin scripts); good
//  enough for budgeting with margin.
//

import Foundation

public enum TokenBudget {
    /// Apple on-device SystemLanguageModel context window (tokens).
    public static let appleContext = 4_096
    /// Rough chars-per-token for budgeting (Latin scripts).
    public static let charsPerToken = 4

    public static func approxTokens(_ s: String) -> Int {
        max(1, s.count / charsPerToken)
    }

    public static func approxChars(tokens: Int) -> Int {
        tokens * charsPerToken
    }

    /// Split text into chunks each ≤ `maxTokens`, breaking on line
    /// boundaries where possible and hard-splitting any oversized line.
    public static func chunk(_ text: String, maxTokens: Int) -> [String] {
        let maxChars = max(1, approxChars(tokens: maxTokens))
        if text.count <= maxChars { return [text] }

        var chunks: [String] = []
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = rawLine + "\n"
            if current.count + piece.count > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if piece.count > maxChars {
                var rest = Substring(piece)
                while rest.count > maxChars {
                    chunks.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
                current += String(rest)
            } else {
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Truncate text to fit `maxTokens` (used for one-shot prompts where
    /// dropping the tail is acceptable).
    public static func clamp(_ text: String, maxTokens: Int) -> String {
        let maxChars = max(1, approxChars(tokens: maxTokens))
        return text.count <= maxChars ? text : String(text.prefix(maxChars))
    }
}
