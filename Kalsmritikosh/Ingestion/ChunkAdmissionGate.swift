//
//  ChunkAdmissionGate.swift
//  Kalsmritikosh
//
//  Stage 1 of the ingestion quality gate (see docs/INGEST_QUALITY_TIERING_PLAN.md).
//  Deterministic, on-device, no LLM. Decides whether a chunk is worth EMBEDDING
//  (and vector-indexing) — the "do not embed everything" rule. It never deletes
//  text: a non-admitted chunk is still stored and citable; it is only excluded
//  from the semantic vector index.
//
//  Conservative by design: it only skips content that is unambiguously
//  non-substantive (blank, tiny fragment, a bare page number, or a lone
//  navigation token). Anything that might be real content is admitted — the
//  project's core directive is to preserve everything, and over-admitting a
//  borderline chunk is always preferred to dropping real signal. Cross-document
//  boilerplate (signatures / disclaimers / repeated footers) is handled
//  separately by the BoilerplateRegistry wiring (Stage 1b), not here.
//

import Foundation

public enum ChunkAdmission: Equatable, Sendable {
    case admit
    case skipBlank
    case skipTooShort
    case skipPageNumber
    case skipNavigation

    public var admitted: Bool { self == .admit }
    /// Stored/logged reason string (nil when admitted).
    public var skipReason: String? {
        switch self {
        case .admit:           return nil
        case .skipBlank:       return "blank"
        case .skipTooShort:    return "too_short"
        case .skipPageNumber:  return "page_number"
        case .skipNavigation:  return "navigation"
        }
    }
}

public enum ChunkAdmissionGate {

    /// Chunks with fewer than this many non-whitespace characters carry no
    /// embeddable signal. Deliberately small (a real one-line paragraph like
    /// "Payment received." is ~17 chars and MUST pass); tuned against the real
    /// corpus so genuine short content is not skipped.
    public static let minMeaningfulChars = 12

    /// Lone navigation tokens that appear as their own chunk in web/exported
    /// content. Matched only when the WHOLE trimmed chunk equals one of these
    /// (case-insensitive) — never as a substring of real prose.
    private static let navigationTokens: Set<String> = [
        "next", "previous", "prev", "back", "home", "menu", "top",
        "skip to content", "skip to main content", "read more", "continue",
        "click here", "return to top", "back to top"
    ]

    public static func evaluate(_ text: String) -> ChunkAdmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .skipBlank }

        // Count non-whitespace characters (a chunk of only spaces/newlines,
        // or a couple of stray glyphs, has no embeddable signal).
        let meaningful = trimmed.unicodeScalars.reduce(0) { acc, s in
            CharacterSet.whitespacesAndNewlines.contains(s) ? acc : acc + 1
        }
        if meaningful < minMeaningfulChars {
            // Short-but-meaningful exceptions: keep it if it contains a digit
            // AND a letter (e.g. "Invoice #42", "Q3 2024") — small but real.
            if hasLetter(trimmed) && hasDigit(trimmed) { /* keep evaluating */ }
            else if isPageNumber(trimmed) { return .skipPageNumber }
            else if isNavigation(trimmed) { return .skipNavigation }
            else { return .skipTooShort }
        }

        // Longer chunks: only skip the unambiguous non-content shapes.
        if isPageNumber(trimmed) { return .skipPageNumber }
        if isNavigation(trimmed) { return .skipNavigation }
        return .admit
    }

    // MARK: - Shape tests

    /// A chunk that is ONLY a page marker: "3", "Page 3", "Page 3 of 10",
    /// "3 / 10", "- 3 -", "[3]". Requires the whole trimmed string to match.
    private static func isPageNumber(_ s: String) -> Bool {
        let lower = s.lowercased()
        let patterns = [
            #"^\d{1,4}$"#,
            #"^page\s+\d{1,4}$"#,
            #"^page\s+\d{1,4}\s*(of|/)\s*\d{1,4}$"#,
            #"^\d{1,4}\s*(of|/)\s*\d{1,4}$"#,
            #"^[-–—\[\(]\s*\d{1,4}\s*[-–—\]\)]$"#
        ]
        for p in patterns where lower.range(of: p, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isNavigation(_ s: String) -> Bool {
        let key = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return navigationTokens.contains(key)
    }

    private static func hasLetter(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
    private static func hasDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { ("0"..."9").contains(Character($0)) }
    }
}
