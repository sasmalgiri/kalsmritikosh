//
//  OCRLine.swift
//  Kalsmritikosh
//
//  U-4 (implement-all) — the ACCOUNTABLE OCR unit. Vision used to hand
//  back bare strings and a single per-image mean confidence, so a
//  misread patent number was indistinguishable from a clean line. An
//  OCRLine carries its own text, confidence, and bounding box (normalized
//  0–1, Vision's coordinate space), so evidence can mark a low-confidence
//  line and a click can highlight its region on the image.
//
//  The identifier policy is PURE and CI-tested: it decides when a line is
//  identifier-shaped, which is the signal to turn Vision's language
//  correction OFF for it — "202331019665" must never be "autocorrected"
//  into a dictionary word.
//

import Foundation
import CoreGraphics

public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let confidence: Float          // 0…1 from Vision's top candidate
    public let boundingBox: CGRect        // normalized, origin bottom-left

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    public enum ConfidenceBand: String, Sendable { case low, medium, high }

    /// Band for the evidence marker. Vision printed-text confidence runs
    /// high; < 0.5 is genuinely doubtful, 0.5–0.8 worth a soft mark.
    public var band: ConfidenceBand {
        switch confidence {
        case ..<0.5:  return .low
        case ..<0.8:  return .medium
        default:      return .high
        }
    }

    /// True when this line should carry a low-confidence marker on the
    /// evidence surface.
    public var isLowConfidence: Bool { band == .low }
}

public enum OCRTextPolicy {

    /// An identifier-shaped line is dominated by digits / codes, not prose:
    /// a patent or application number, an account or case number, a
    /// reference code. Language correction must be OFF for these — a
    /// dictionary "fix" corrupts the very characters that matter.
    /// Deterministic: ≥ 40% of the line's characters are digits, OR it
    /// matches a compact alphanumeric-code shape with a long digit run.
    public nonisolated static func isIdentifierShaped(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        if isIdentifierToken(trimmed) { return true }
        // A label ("Case No:", "Application No.") dilutes the whole-line
        // ratio, so test the STRONGEST whitespace-separated token too: a
        // code token like "CS/1234/2023" is an identifier even inside prose.
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains { isIdentifierToken(String($0)) }
    }

    nonisolated static func isIdentifierToken(_ token: String) -> Bool {
        guard token.count >= 4 else { return false }
        let digits = token.filter(\.isNumber).count
        guard digits >= 1 else { return false }
        let letters = token.filter(\.isLetter).count
        // Mostly digits (counting code separators / and - toward the code).
        let codeChars = token.filter { $0.isNumber || $0 == "/" || $0 == "-" }.count
        if Double(codeChars) / Double(token.count) >= 0.4 { return true }
        // A long unbroken digit run (≥5) with no more letters than digits.
        if longestDigitRun(token) >= 5 && letters <= digits { return true }
        return false
    }

    nonisolated static func longestDigitRun(_ s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            if ch.isNumber { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }
}
