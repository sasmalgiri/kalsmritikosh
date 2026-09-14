//
//  DomainPackText.swift
//  Kalsmritikosh
//
//  Shared, deterministic text helpers for the starter domain packs
//  (medical, legal-case, vital-records, financial-statement, property,
//  identity). One place for "value after a label" and "first date in
//  text" so each pack stays a thin, readable field table. Offline, pure.
//

import Foundation

public enum DomainPackText {

    /// The value that follows one of `markers` on the same line, up to the
    /// next delimiter. Markers are matched case-insensitively; the longest
    /// sensible single-line value (2…80 chars) is returned, else nil. The
    /// leading separator (":", "-", "of") is consumed.
    public nonisolated static func labeledValue(after markers: [String], in text: String) -> String? {
        let lower = text.lowercased()
        for m in markers {
            var searchStart = lower.startIndex
            while let r = lower.range(of: m, range: searchStart..<lower.endIndex) {
                // Map the lowercase range onto the original text by offset.
                let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let afterIdx = text.index(text.startIndex, offsetBy: startOffset)
                var slice = Substring(text[afterIdx...])
                // Consume a separator run (": ", " - ", " of ", whitespace).
                slice = slice.drop { $0 == ":" || $0 == "-" || $0 == " " || $0 == "\t" }
                if slice.lowercased().hasPrefix("of ") { slice = slice.dropFirst(3) }
                let value = slice.prefix { !"\n\r.,;|()".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 2 && value.count <= 80 { return value }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    /// The first date-shaped token in the text (dd/mm/yyyy, dd-mm-yyyy, or
    /// "12 March 2024" / "March 12, 2024"). Returned raw for the caller to
    /// pass through `PatentDomainPack.normalizeDate`.
    public nonisolated static func firstDate(in text: String) -> String? {
        let pattern =
            #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"# +
            #"|\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Za-z]*\.?\s+\d{2,4}\b"# +
            #"|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Za-z]*\.?\s+\d{1,2},?\s+\d{2,4}\b"#
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r])
    }

    /// The first money-shaped token (₹, Rs, INR, $, £, €), or nil.
    public nonisolated static func firstMoney(in text: String) -> String? {
        let pattern = #"(?:₹|rs\.?|inr|\$|£|€)\s?[\d,]+(?:\.\d{1,2})?"#
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    /// Currency code from a matched money string, for the fact's `unit`.
    public nonisolated static func currencyUnit(_ money: String) -> String? {
        let a = money.lowercased()
        if a.contains("₹") || a.contains("rs") || a.contains("inr") { return "INR" }
        if a.contains("$") { return "USD" }
        if a.contains("£") { return "GBP" }
        if a.contains("€") { return "EUR" }
        return nil
    }

    /// A bare identifier following a label (case/account/id/registration
    /// numbers): letters+digits, 4…40 chars, slashes and hyphens allowed.
    public nonisolated static func labeledIdentifier(after markers: [String], in text: String) -> String? {
        let lower = text.lowercased()
        for m in markers {
            guard let r = lower.range(of: m) else { continue }
            let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
            let afterIdx = text.index(text.startIndex, offsetBy: startOffset)
            var slice = Substring(text[afterIdx...])
            slice = slice.drop { $0 == ":" || $0 == "-" || $0 == " " || $0 == "\t" || $0 == "#" }
            if slice.lowercased().hasPrefix("no ") { slice = slice.dropFirst(3) }
            if slice.lowercased().hasPrefix("no.") { slice = slice.dropFirst(3) }
            let value = slice.prefix { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" }
            let clean = String(value).trimmingCharacters(in: .whitespaces)
            if clean.count >= 4, clean.count <= 40, clean.contains(where: \.isNumber) { return clean }
        }
        return nil
    }
}
