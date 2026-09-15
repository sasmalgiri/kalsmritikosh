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

    /// The value of a genuinely LABELED field: `marker` must be followed
    /// (after optional spaces) by a `:` or `-` separator — i.e. it is a form
    /// field "Label: value", not an incidental word in prose. This is the
    /// live-archive hardening: the loose "marker anywhere → grab what
    /// follows" rule mislabelled a base64 email token as a medication and a
    /// police "FIR NO" as a diagnosis. The captured value must also pass
    /// `isPlausibleFieldValue` (no MIME/base64 shrapnel). 2…80 chars.
    public nonisolated static func labeledValue(after markers: [String], in text: String) -> String? {
        let lower = text.lowercased()
        for m in markers {
            var searchStart = lower.startIndex
            while let r = lower.range(of: m, range: searchStart..<lower.endIndex) {
                let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let afterIdx = text.index(text.startIndex, offsetBy: startOffset)
                var slice = Substring(text[afterIdx...])
                // REQUIRE a label separator: skip spaces, then the next char
                // must be ':' or '-'. Prose ("…diagnosis of the office…") has
                // no separator and is rejected here.
                let spaces = slice.prefix { $0 == " " || $0 == "\t" }
                slice = slice.dropFirst(spaces.count)
                guard let sep = slice.first, sep == ":" || sep == "-" else {
                    searchStart = r.upperBound; continue
                }
                slice = slice.dropFirst()
                slice = slice.drop { $0 == " " || $0 == "\t" }
                let value = slice.prefix { !"\n\r.,;|()".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.count <= 80, isPlausibleFieldValue(value) {
                    return value
                }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    /// Rejects the junk the live archive surfaced: MIME/base64 shrapnel
    /// ("TOJXAijyAQ-3D-3D", tokens with '=' or a long unbroken mixed
    /// case+digit run with no spaces). A real field value is words, a name,
    /// a number, or a short code — not an encoded blob.
    public nonisolated static func isPlausibleFieldValue(_ value: String) -> Bool {
        if value.contains("=") || value.contains("-3D") || value.contains("_3D") { return false }
        // A long no-space token that mixes upper, lower AND digits is
        // almost always an encoded id, not a field value.
        if !value.contains(" ") && value.count >= 12 {
            let hasUpper = value.contains { $0.isUppercase }
            let hasLower = value.contains { $0.isLowercase }
            let hasDigit = value.contains { $0.isNumber }
            if hasUpper && hasLower && hasDigit { return false }
        }
        return true
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

    /// A date that appears WITHIN `window` characters after one of the
    /// label phrases — a labeled date ("hearing on 5 Dec 2024", "executed on
    /// 20-08-2019"), not merely any date in a block that tripped a marker.
    /// This is the live-archive fix for hearingdate/deeddate firing on bare
    /// dates anywhere in a patent email. Returns the raw date for
    /// normalizeDate.
    public nonisolated static func labeledDate(after phrases: [String], in text: String, window: Int = 40) -> String? {
        let lower = text.lowercased()
        for p in phrases {
            var searchStart = lower.startIndex
            while let r = lower.range(of: p, range: searchStart..<lower.endIndex) {
                let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let afterIdx = text.index(text.startIndex, offsetBy: startOffset)
                let endIdx = text.index(afterIdx, offsetBy: min(window, text.distance(from: afterIdx, to: text.endIndex)))
                if let raw = firstDate(in: String(text[afterIdx..<endIdx])) { return raw }
                searchStart = r.upperBound
            }
        }
        return nil
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
