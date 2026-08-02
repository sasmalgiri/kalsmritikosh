//
//  TypedFieldExtractor.swift
//  Kalsmritikosh
//
//  MMI-FINAL — the deterministic typed-field producer. It reads ALREADY-ACCEPTED
//  EvidenceBlocks and extracts identity/document fields (personName, documentNumber,
//  issueDate, email, amount, …) via labeled + pattern rules. NO model call, NO network, NO
//  guessing: every emitted field is pinned to the exact block it came from, carries the
//  block's locator (page / bounding box / char range), and its confidence is derived
//  deterministically from the match kind + the block's extraction method/confidence (OCR/
//  vision text is trusted less than native text). A typed field is NOT a Claim.
//

import Foundation

public nonisolated struct TypedFieldExtractor: Sendable {
    public let producerID: String
    public let producerVersion: String

    public init(producerID: String = "mmi.typed-field", producerVersion: String = "1") {
        self.producerID = producerID
        self.producerVersion = producerVersion
    }

    /// Extract typed fields from a version's blocks. Deterministic + order-stable.
    public func extract(blocks: [EvidenceBlock], sourceVersionID: UUID, at when: Date = Date()) -> [TypedField] {
        var out: [TypedField] = []
        var seen = Set<String>()   // dedup by (blockID, fieldType, normalizedValue)
        for block in blocks where !block.kind.isBoilerplate {
            let text = block.rawText.isEmpty ? block.normalizedText : block.rawText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for (type, raw, conf) in Self.candidates(in: text, block: block) {
                let normalized = Self.normalize(type, raw)
                guard !normalized.isEmpty else { continue }
                let key = "\(block.id.uuidString)|\(type.rawValue)|\(normalized)"
                guard seen.insert(key).inserted else { continue }
                var locator = block.locator
                locator.evidenceBlockID = block.id
                out.append(TypedField(
                    sourceVersionID: sourceVersionID, evidenceBlockID: block.id, fieldType: type,
                    rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines), normalizedValue: normalized,
                    confidence: conf, extractionMethod: block.extractionMethod, locator: locator,
                    ocrConfidence: block.extractionMethod == .ocr ? block.extractionConfidence : nil,
                    boundingBox: block.locator.boundingBox,
                    producerID: producerID, producerVersion: producerVersion, createdAt: when))
            }
        }
        return out
    }

    // MARK: - Deterministic candidate rules

    /// The confidence multiplier a block's provenance earns: native text is trusted fully,
    /// OCR/vision scaled by the block's own extraction confidence.
    static func methodFactor(_ block: EvidenceBlock) -> Double {
        switch block.extractionMethod {
        case .native, .manual: return 1.0
        case .ocr, .vision, .asr, .api: return max(0.1, block.extractionConfidence)
        }
    }

    static func candidates(in text: String, block: EvidenceBlock) -> [(TypedFieldType, String, Double)] {
        var results: [(TypedFieldType, String, Double)] = []
        let factor = methodFactor(block)

        // 1) Labeled fields — highest confidence (a label unambiguously names the field).
        let labeled: [(TypedFieldType, [String])] = [
            (.personName, ["full name", "name of holder", "holder name", "name"]),
            (.organizationName, ["organization", "organisation", "company", "issued by", "issuing authority", "employer"]),
            (.dateOfBirth, ["date of birth", "d.o.b", "dob", "birth date"]),
            (.issueDate, ["date of issue", "issue date", "issued on", "issued", "date issued"]),
            (.expiryDate, ["date of expiry", "expiry date", "expiration date", "valid until", "valid upto", "valid up to", "expires"]),
            (.documentNumber, ["passport no", "passport number", "document no", "document number", "id no", "id number", "licence no", "license no", "card no", "no."]),
            (.invoiceNumber, ["invoice no", "invoice number", "invoice #", "bill no"]),
            (.referenceNumber, ["reference no", "reference number", "ref no", "ref #", "reference"]),
            (.accountIdentifier, ["account no", "account number", "a/c no", "a/c", "iban"]),
            (.taxIdentifier, ["pan", "gstin", "tax id", "tin", "vat no", "ssn", "national id"]),
            (.address, ["address", "residence", "resident of"]),
            (.email, ["email", "e-mail"]),
            (.phone, ["phone", "mobile", "tel", "contact no", "contact number"]),
        ]
        for (type, labels) in labeled {
            guard let value = labeledValue(in: text, labels: labels) else { continue }
            let extracted = refine(type, value)
            guard let extracted, !extracted.isEmpty else { continue }
            results.append((type, extracted, min(0.97, 0.9 * factor)))
        }

        // 2) Pattern-only fields — present without a label (still deterministic + located).
        if !results.contains(where: { $0.0 == .email }) {
            for m in matches(in: text, pattern: Self.emailPattern) {
                results.append((.email, m, 0.85 * factor))
            }
        }
        if !results.contains(where: { $0.0 == .phone }) {
            for m in matches(in: text, pattern: Self.phonePattern) where Self.digitCount(m) >= 8 && Self.digitCount(m) <= 15 {
                results.append((.phone, m, 0.6 * factor))
            }
        }
        for m in matches(in: text, pattern: Self.amountPattern) {
            results.append((.amount, m, 0.7 * factor))
            if let cur = firstMatch(in: m, pattern: Self.currencyPattern) {
                results.append((.currency, cur, 0.7 * factor))
            }
        }

        // 3) A short title/header block that looks like a name (no digits, Title Case) is a
        //    LOW-confidence person-name candidate — surfaced, never asserted.
        if !results.contains(where: { $0.0 == .personName }),
           (block.kind == .documentTitle || block.kind == .documentHeader || block.kind == .sectionHeading),
           Self.looksLikePersonName(text) {
            results.append((.personName, text, 0.45 * factor))
        }
        return results
    }

    // MARK: - Label + value extraction

    /// The value following a label on the same line (after an optional ':'), or the next
    /// non-empty line when the label's own line has no value.
    static func labeledValue(in text: String, labels: [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            for label in labels {
                guard let r = lower.range(of: label) else { continue }
                // The label must be a word-boundary hit (avoid "name" inside "surname"? allow, but
                // require the label to start the token or follow whitespace/':').
                let before = r.lowerBound == lower.startIndex ? " " : String(lower[lower.index(before: r.lowerBound)])
                guard before == " " || before == "\t" || before == ":" || before == "-" else { continue }
                var rest = String(line[r.upperBound...])
                if let colon = rest.firstIndex(of: ":") { rest = String(rest[rest.index(after: colon)...]) }
                let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t:-#").union(.whitespaces))
                if !trimmed.isEmpty { return trimmed }
                // value on the next line
                if i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if !next.isEmpty { return next }
                }
            }
        }
        return nil
    }

    /// Pull the actual value out of a labeled remainder for structured types.
    static func refine(_ type: TypedFieldType, _ value: String) -> String? {
        switch type {
        case .dateOfBirth, .issueDate, .expiryDate:
            return firstMatch(in: value, pattern: Self.datePattern) ?? value
        case .documentNumber, .invoiceNumber, .referenceNumber, .accountIdentifier, .taxIdentifier:
            return firstMatch(in: value, pattern: Self.identifierPattern) ?? value
        case .email:
            return firstMatch(in: value, pattern: Self.emailPattern) ?? value
        case .phone:
            return firstMatch(in: value, pattern: Self.phonePattern) ?? value
        default:
            // Names/orgs/addresses: cut at a trailing double-space column or another label.
            return value.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Normalization

    static func normalize(_ type: TypedFieldType, _ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .email:                                    return collapsed.lowercased()
        case .phone:                                    return collapsed.filter { $0.isNumber || $0 == "+" }
        case .amount:                                   return collapsed.filter { $0.isNumber || $0 == "." }
        case .currency:                                 return Self.normalizeCurrency(collapsed)
        case .documentNumber, .invoiceNumber, .referenceNumber, .accountIdentifier, .taxIdentifier:
            return collapsed.uppercased()
        case .personName, .organizationName:            return collapsed
        default:                                        return collapsed
        }
    }

    static func normalizeCurrency(_ s: String) -> String {
        switch s.uppercased() {
        case "₹", "RS", "RS.", "INR": return "INR"
        case "$", "USD":              return "USD"
        case "€", "EUR":              return "EUR"
        case "£", "GBP":              return "GBP"
        default:                      return s.uppercased()
        }
    }

    static func looksLikePersonName(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60, !t.contains(where: \.isNumber) else { return false }
        let words = t.split(separator: " ")
        guard (2...4).contains(words.count) else { return false }
        return words.allSatisfy { $0.first?.isUppercase == true }
    }

    // MARK: - Regex helpers (deterministic)

    static let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    static let phonePattern = "\\+?\\d[\\d ()\\-.]{6,}\\d"
    static let amountPattern = "(?:₹|\\$|€|£|Rs\\.?|INR|USD|EUR|GBP)\\s?[0-9][0-9,]*(?:\\.[0-9]+)?"
    static let currencyPattern = "₹|\\$|€|£|INR|USD|EUR|GBP|Rs\\.?"
    static let identifierPattern = "[A-Za-z0-9][A-Za-z0-9\\-/]{3,}"
    static let datePattern =
        "\\d{1,2}[/\\-.]\\d{1,2}[/\\-.]\\d{2,4}" +
        "|\\d{1,2}\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Za-z]*\\.?\\s+\\d{2,4}" +
        "|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Za-z]*\\.?\\s+\\d{1,2},?\\s+\\d{2,4}"

    static func digitCount(_ s: String) -> Int { s.filter(\.isNumber).count }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r])
    }

    static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
