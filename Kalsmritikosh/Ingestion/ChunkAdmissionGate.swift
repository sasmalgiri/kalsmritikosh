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
    case skipEmailHeader

    public var admitted: Bool { self == .admit }
    /// Stored/logged reason string (nil when admitted).
    public var skipReason: String? {
        switch self {
        case .admit:           return nil
        case .skipBlank:       return "blank"
        case .skipTooShort:    return "too_short"
        case .skipPageNumber:  return "page_number"
        case .skipNavigation:  return "navigation"
        case .skipEmailHeader: return "email_header"
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

    /// Email header field prefixes. A chunk that is a single short line
    /// beginning with one of these is pure metadata (From/To/Subject/Date/…) —
    /// already captured as structured fields/entities by the email loader, so
    /// embedding it as a standalone semantic vector adds nothing and floods the
    /// index (an mbox repeats "From: x" once per message). Guarded by
    /// single-line + <80 chars so a "Date: <date> <body…>" chunk (where body
    /// merged onto the header line) is NEVER treated as a header.
    private static let emailHeaderPrefixes = [
        "from:", "to:", "cc:", "bcc:", "subject:", "date:", "sent:", "reply-to:"
    ]

    public static func evaluate(_ text: String) -> ChunkAdmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .skipBlank }
        if isEmailHeaderLine(trimmed) { return .skipEmailHeader }

        // Count non-whitespace characters (a chunk of only spaces/newlines,
        // or a couple of stray glyphs, has no embeddable signal).
        let meaningful = trimmed.unicodeScalars.reduce(0) { acc, s in
            CharacterSet.whitespacesAndNewlines.contains(s) ? acc : acc + 1
        }
        if meaningful < minMeaningfulChars {
            // PROTECTED short content — short text is often the most decisive
            // evidence ("Paid", "Denied", "Approved", "₹8,500", "12/06/2026",
            // "Clause 7", "Yes", "No", "Not signed"). Keep any short chunk that
            // carries a status/decision word, negation, amount, date, identifier,
            // or letter+digit token; only fall through to skip when it is truly
            // non-substantive (page number, nav token, or a bare fragment).
            // Shape checks FIRST so "Page 3 of 10" is treated as a page marker
            // even though it contains a letter+digit (which would otherwise
            // trip the protected-signal rule below).
            if isPageNumber(trimmed) { return .skipPageNumber }
            if isNavigation(trimmed) { return .skipNavigation }
            if hasProtectedShortSignal(trimmed) { return .admit }
            return .skipTooShort
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

    /// A single short line that is only an email header field. Mirrors the
    /// SQL-validated rule: no internal newline, <80 chars, begins with a known
    /// header prefix. The length + single-line guard guarantees a header line
    /// that absorbed body text (long) is kept, not skipped (0 body false
    /// positives verified on the real corpus).
    private static func isEmailHeaderLine(_ trimmed: String) -> Bool {
        guard trimmed.count < 80, !trimmed.contains("\n") else { return false }
        let lower = trimmed.lowercased()
        return emailHeaderPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func hasLetter(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
    private static func hasDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { ("0"..."9").contains(Character($0)) }
    }

    /// Status / decision / negation words whose mere presence makes a short
    /// chunk decisive evidence. Matched as whole tokens (case-insensitive).
    private static let statusWords: Set<String> = [
        "paid", "unpaid", "due", "overdue", "denied", "approved", "rejected",
        "accepted", "declined", "granted", "refused", "signed", "unsigned",
        "void", "cancelled", "canceled", "confirmed", "pending", "closed",
        "open", "yes", "no", "not", "none", "na", "n/a", "agreed", "complete",
        "completed", "incomplete", "failed", "passed", "success", "settled",
        "outstanding", "waived", "expired", "active", "inactive", "terminated"
    ]

    /// True when a short chunk carries a protected signal — an amount, date,
    /// identifier, letter+digit token, or a status/decision/negation word — so
    /// it must NOT be dropped from the vector index just for being short.
    private static func hasProtectedShortSignal(_ trimmed: String) -> Bool {
        // Amount (currency symbol anywhere).
        if trimmed.unicodeScalars.contains(where: { "$€£₹¥₩¢".unicodeScalars.contains($0) }) { return true }
        // Date-ish: two number groups joined by / . or - (12/06/2026, 6-1-25).
        if trimmed.range(of: #"\d{1,4}[/.\-]\d{1,2}"#, options: .regularExpression) != nil { return true }
        // Identifier / labelled number (letter AND digit): "Clause 7", "#42", "Q3".
        if hasLetter(trimmed) && hasDigit(trimmed) { return true }
        // Status / decision / negation word as a whole token.
        let tokens = trimmed.lowercased().split { !$0.isLetter && $0 != "/" }.map(String.init)
        return tokens.contains { statusWords.contains($0) }
    }
}
