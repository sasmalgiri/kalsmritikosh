//
//  StudioEvidenceResolver.swift
//  Kalsmritikosh
//
//  Final brief §3.2 / ship-readiness review R1 — "evidenced" means the evidence was RESOLVED, by the
//  kind of field it supports. At preview and export, every field the gate would call evidenced is
//  checked against the draft's own case, under the current access policy:
//    • the draft is assigned to a case (otherwise nothing can be checked);
//    • a PASSAGE reference (block): its source version is in the case and accessible, the block still
//      exists in exactly that version (unknown provenance fails), and the quoted words are in it;
//    • an OBJECT reference: the document is in the case, the reference names the exact source version
//      it was read from and the document belongs to that version, and the quoted words are in its text;
//    • a DOCUMENT-NAME reference (the quote is the file's name) supports only a document-inventory
//      field ("materials relied upon", "documents") — never an amount, a date or a finding;
//    • the field's VALUE is supported by the passage, by kind: an amount must appear with the same
//      exact value and no conflicting currency (₹1,000 is not supported by "USD 1,000"); a date must
//      be the same day; text of any length must appear in full — a quotation attached to a different
//      conclusion is not support.
//  A field that does not resolve is reported with the reason. The person may then say it is their own
//  entry — it is printed as such, never as documentary evidence. An edited field already lost its
//  documentary status (StudioExportGate.status).
//

import Foundation

public nonisolated struct StudioEvidenceContext: Sendable {
    public let eligibleSourceVersions: Set<UUID>
    public let caseObjects: Set<UUID>
    public let documentNames: [UUID: String]
    /// Each case document → the case's source versions it belongs to.
    public let objectVersions: [UUID: Set<UUID>]
    public let blockText: @Sendable (UUID) async -> (sourceVersionID: UUID?, text: String)?
    public let objectText: @Sendable (UUID) async -> String?

    public init(eligibleSourceVersions: Set<UUID>, caseObjects: Set<UUID>, documentNames: [UUID: String],
                objectVersions: [UUID: Set<UUID>] = [:],
                blockText: @escaping @Sendable (UUID) async -> (sourceVersionID: UUID?, text: String)?,
                objectText: @escaping @Sendable (UUID) async -> String?) {
        self.eligibleSourceVersions = eligibleSourceVersions; self.caseObjects = caseObjects; self.documentNames = documentNames
        self.objectVersions = objectVersions; self.blockText = blockText; self.objectText = objectText
    }
}

/// What a studio field holds, which decides what can support it.
public nonisolated enum StudioFieldKind: Sendable, Equatable {
    case documentInventory, amount, date, text

    /// From the field's path and value: inventory paths ("materials.…", "documents.…", "….source",
    /// "….sourceDoc"); amount paths or values with a currency; ISO or written dates; else text.
    public static func of(path: String, value: String) -> StudioFieldKind {
        let p = path.lowercased()
        if p.hasPrefix("materials.") || p.hasPrefix("documents.") || p.hasSuffix(".source") || p.hasSuffix(".sourcedoc") || p.hasSuffix(".document") {
            return .documentInventory
        }
        if p.contains("amount") || (!FAMoney.currency(of: value).isEmpty && FAMoney.value(of: value) != nil && value.count <= 40) { return .amount }
        if p.contains("date") || StudioEvidenceResolver.wholeDate(value) != nil { return .date }
        return .text
    }
}

public nonisolated enum StudioEvidenceResolver {

    public static let notAssigned = "the draft is not assigned to a case, so its sources cannot be checked — use Fill from case"

    /// Field path → why its documentary support did not resolve. Only fields the gate would count as
    /// evidenced are checked; empty, unsupported and investigator-entry fields are not.
    public static func unresolved(values: [String: String], provenance: StudioProvenance?,
                                  context: StudioEvidenceContext?) async -> [String: String] {
        var out: [String: String] = [:]
        for path in values.keys.sorted() {
            let value = values[path] ?? ""
            guard StudioExportGate.status(of: value, provenance: provenance?[path]) == .evidenced,
                  let refs = provenance?[path]?.evidence else { continue }
            guard let context else { out[path] = notAssigned; continue }
            let kind = StudioFieldKind.of(path: path, value: value)
            var reason = "no source is recorded"
            var resolved = false
            for ref in refs {
                switch await check(ref, value: value, kind: kind, context) {
                case nil: resolved = true
                case let r?: reason = r
                }
                if resolved { break }
            }
            if !resolved { out[path] = reason }
        }
        return out
    }

    /// nil when the reference resolves for a field of `kind`; otherwise the reason.
    static func check(_ ref: StudioEvidenceRef, value: String, kind: StudioFieldKind = .text, _ c: StudioEvidenceContext) async -> String? {
        guard let quote = ref.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else {
            return "the reference quotes no passage"
        }
        let q = norm(quote)
        if let block = ref.blockID {
            guard let version = ref.sourceVersionID else { return "the passage reference names no source version" }
            guard c.eligibleSourceVersions.contains(version) else { return "the cited source is not in this case or is not accessible" }
            guard let b = await c.blockText(block) else { return "the cited passage no longer exists" }
            guard let bv = b.sourceVersionID else { return "the cited passage's source version is unknown" }
            guard bv == version else { return "the cited passage belongs to a different version of the source" }
            guard norm(b.text).contains(q) else { return "the quoted words are not in the cited passage" }
            return supports(value, kind: kind, quote: quote)
        }
        if let object = ref.objectID {
            guard c.caseObjects.contains(object) else { return "the cited document is not in this case or is not accessible" }
            // A document's name supports only a document-inventory line.
            if let name = c.documentNames[object], norm(name) == q {
                return kind == .documentInventory ? nil : "the reference is only the document's name — it does not state this value"
            }
            // A factual citation names the exact version it was read from.
            if kind != .documentInventory {
                guard let version = ref.sourceVersionID else { return "the reference names no source version" }
                guard c.eligibleSourceVersions.contains(version), c.objectVersions[object]?.contains(version) == true else {
                    return "the cited document is not in the cited version of the source"
                }
            }
            guard let text = await c.objectText(object) else { return "the cited document cannot be read" }
            guard norm(text).contains(q) else { return "the quoted words are not in the cited document" }
            return supports(value, kind: kind, quote: quote)
        }
        if let version = ref.sourceVersionID {
            return c.eligibleSourceVersions.contains(version) ? "the reference names a source but no passage in it" : "the cited source is not in this case or is not accessible"
        }
        return "the reference names no source"
    }

    /// nil when the passage supports the whole value, by kind; otherwise the reason.
    static func supports(_ value: String, kind: StudioFieldKind, quote: String) -> String? {
        let v = norm(value)
        guard !v.isEmpty else { return nil }
        switch kind {
        case .documentInventory:
            return norm(quote).contains(v) ? nil : "the cited passage does not name this document"
        case .amount:
            guard let want = FAMoney.value(of: value) else { return "the amount cannot be read exactly" }
            let wantCurrency = FAMoney.currency(of: value)
            for token in amountTokens(in: quote) {
                guard let got = FAMoney.value(of: token), got.magnitude == want.magnitude, (got < 0) == (want < 0) else { continue }
                let gotCurrency = FAMoney.currency(of: token)
                if !wantCurrency.isEmpty, !gotCurrency.isEmpty, wantCurrency != gotCurrency { continue }
                return nil
            }
            return "the cited passage does not state this amount (same value and currency)"
        case .date:
            guard let want = wholeDate(value) else { return "the date cannot be read exactly" }
            let cal = Calendar(identifier: .gregorian)
            for d in dates(in: quote) where cal.isDate(d, inSameDayAs: want) { return nil }
            return "the cited passage does not state this date"
        case .text:
            return norm(quote).contains(v) ? nil : "the cited passage does not state this — a conclusion drawn from it is your own entry"
        }
    }

    /// Amounts as written in a passage ("₹1,000", "USD 1,000.50", "Rs. 2,500", "(1,200)").
    static func amountTokens(in text: String) -> [String] {
        let pattern = #"(?:\b(?:USD|EUR|GBP|INR|JPY|CNY|AUD|CAD|CHF|SGD|AED|HKD|NZD|ZAR|SEK|NOK|DKK|SAR|BRL|MXN)\s?|[₹$€£]\s?|Rs\.?\s?|(?:CA|US|A|NZ|HK|S)\$\s?)?\(?-?\d[\d,]*(?:\.\d+)?\)?(?:\s?(?:USD|EUR|GBP|INR|JPY|CNY|AUD|CAD|CHF|SGD|AED|HKD|NZD|ZAR|SEK|NOK|DKK|SAR|BRL|MXN)\b)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// A value that is one date and nothing else ("2026-01-05", "5 January 2026").
    static func wholeDate(_ value: String) -> Date? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"; iso.timeZone = .current
        if let d = iso.date(from: t) { return d }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)),
              m.range.length >= (t as NSString).length - 1 else { return nil }
        return m.date
    }

    static func dates(in text: String) -> [Date] {
        var out: [Date] = []
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"; iso.timeZone = .current
        if let re = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = iso.date(from: ns.substring(with: m.range)) { out.append(d) }
            }
        }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            out += det.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap(\.date)
        }
        return out
    }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "[“”″]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’′]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[–—]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}
