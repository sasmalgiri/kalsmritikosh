//
//  EntityExtractor.swift
//  Kalsmritikosh
//
//  Baseline extractor combining NLTagger (people/orgs/places),
//  NSDataDetector (dates, money, phones, addresses), and regex
//  (emails, invoice numbers). The Phase 4 model-based extractor
//  swaps in at M3 once the registry is live.
//

import Foundation
import NaturalLanguage

public struct NLEntityExtractor: EntityExtractor {
    public nonisolated init() {}

    public func extractEntities(
        from object: KnowledgeObject,
        chunks: [Chunk],
        blocks: [EvidenceBlock]
    ) async throws -> [Entity] {
        var entities: [Entity] = []
        entities.append(contentsOf: extractNLTagger(object))
        entities.append(contentsOf: extractDetectors(object))
        entities.append(contentsOf: extractRegex(object))
        return Self.attachSourceBlocks(to: entities, blocks: blocks)
    }

    /// A5.4 — attach `sourceBlockIDs` (up to 5) to each entity by matching its
    /// mention text against block normalized text, so a mention's provenance is
    /// the specific block it occurs in. Pure; returns entities unchanged when no
    /// blocks are supplied or no match is found. `static` so it's testable.
    static func attachSourceBlocks(to entities: [Entity], blocks: [EvidenceBlock]) -> [Entity] {
        guard !blocks.isEmpty else { return entities }
        let normalized = blocks.map { (id: $0.id, text: $0.normalizedText.lowercased()) }
        return entities.map { entity in
            let mention = (entity.normalizedValue ?? entity.value).lowercased()
            guard mention.count >= 3 else { return entity }
            let matches = normalized.filter { $0.text.contains(mention) }.prefix(5).map(\.id)
            guard !matches.isEmpty else { return entity }
            return entity.addingAttributes([
                "sourceBlockIDs": AnyCodable(.array(matches.map { .string($0.uuidString) }))
            ])
        }
    }

    // MARK: - NLTagger

    private func extractNLTagger(_ object: KnowledgeObject) -> [Entity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = object.content
        // Force English so NLTagger doesn't log "Unsupported language X
        // detected." on mixed-locale email archives. We're an English-
        // targeted product; non-English entity extraction is not in
        // scope and the auto-detector spams Console with noise.
        if !object.content.isEmpty {
            tagger.setLanguage(.english,
                               range: object.content.startIndex..<object.content.endIndex)
        }
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        var out: [Entity] = []
        tagger.enumerateTags(
            in: object.content.startIndex..<object.content.endIndex,
            unit: .word,
            scheme: .nameType,
            options: opts
        ) { tag, range in
            guard let tag else { return true }
            let kind: Entity.Kind?
            switch tag {
            case .personalName: kind = .person
            case .organizationName: kind = .organization
            case .placeName: kind = .location
            default: kind = nil
            }
            guard let kind else { return true }
            let value = String(object.content[range])
            out.append(Entity(
                kind: kind,
                value: value,
                normalizedValue: value.lowercased(),
                sourceObjectID: object.id,
                confidence: .medium
            ))
            return true
        }
        return out
    }

    // MARK: - NSDataDetector

    private func extractDetectors(_ object: KnowledgeObject) -> [Entity] {
        let types: NSTextCheckingResult.CheckingType = [
            .date, .phoneNumber, .address, .link
        ]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let content = object.content
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = detector.matches(in: content, options: [], range: range)

        return matches.compactMap { match -> Entity? in
            guard let r = Range(match.range, in: content) else { return nil }
            let value = String(content[r])
            switch match.resultType {
            case .date:
                return Entity(
                    kind: .date,
                    value: value,
                    normalizedValue: (match.date.map(ISO8601DateFormatter().string(from:))),
                    sourceObjectID: object.id,
                    confidence: .high
                )
            case .phoneNumber:
                // NSDataDetector over-matches digit-hyphen strings as phone
                // numbers — date ranges ("2015-05 2017-11"), page/number ranges
                // ("2739-2742", "8874–8877"). Suppress the phoneNumber ENTITY
                // for those (the raw text still lives in the chunk/FTS).
                guard Self.isPlausiblePhone(value) else { return nil }
                return Entity(
                    kind: .phoneNumber,
                    value: value,
                    normalizedValue: match.phoneNumber,
                    sourceObjectID: object.id,
                    confidence: .high
                )
            case .address:
                return Entity(
                    kind: .address,
                    value: value,
                    sourceObjectID: object.id,
                    confidence: .medium
                )
            default:
                return nil
            }
        }
    }

    /// NSDataDetector is liberal about what counts as a phone number on
    /// digit-heavy corpora: it tags date ranges ("2015-05 2017-11"), citation
    /// spans ("2739-2742"), and page ranges ("8874–8877") as phones. Accept a
    /// value as a real phone only when it has 7–15 digits AND is neither a
    /// year-month token nor a bare small-integer range. Conservative on purpose
    /// — genuine phones (`+91-40-27160512`, `(022) 6662 0808`, `1800 22 6655`)
    /// pass; the rejected value still lives in the chunk/FTS text.
    static func isPlausiblePhone(_ raw: String) -> Bool {
        // Year-month token anywhere ("2015-05") ⇒ a date range, not a phone.
        if raw.range(of: #"\b(19|20)\d{2}-\d{2}\b"#, options: .regularExpression) != nil {
            return false
        }
        let digitCount = raw.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
        guard (7...15).contains(digitCount) else { return false }
        // Bare small-integer range ("2739-2742", "8874–8877"): two 3–5 digit
        // groups joined by a dash, no country code / grouping / parens. That is
        // a citation or page range, not a phone.
        if raw.range(of: #"^\s*\d{3,5}\s*[-–—]\s*\d{3,5}\s*$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    // MARK: - Regex

    private func extractRegex(_ object: KnowledgeObject) -> [Entity] {
        let content = object.content
        var out: [Entity] = []

        // Emails
        let emailPattern = #"[\w._%+-]+@[\w.-]+\.[A-Za-z]{2,}"#
        if let regex = try? NSRegularExpression(pattern: emailPattern) {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for m in regex.matches(in: content, range: range) {
                if let r = Range(m.range, in: content) {
                    let v = String(content[r])
                    out.append(Entity(
                        kind: .emailAddress,
                        value: v,
                        normalizedValue: v.lowercased(),
                        sourceObjectID: object.id,
                        confidence: .high
                    ))
                }
            }
        }

        // Money / currency
        let moneyPattern = #"(?:USD|EUR|GBP|INR|\$|€|£|₹)\s?\d{1,3}(?:[,\s]\d{3})*(?:\.\d+)?"#
        if let regex = try? NSRegularExpression(pattern: moneyPattern) {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for m in regex.matches(in: content, range: range) {
                if let r = Range(m.range, in: content) {
                    let v = String(content[r])
                    out.append(Entity(
                        kind: .money,
                        value: v,
                        sourceObjectID: object.id,
                        confidence: .medium
                    ))
                }
            }
        }

        // Invoice numbers (loose)
        let invoicePattern = #"(?i)invoice(?:\s+(?:no\.?|number|#))?[:\s]*([A-Z0-9\-/]{3,})"#
        if let regex = try? NSRegularExpression(pattern: invoicePattern) {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for m in regex.matches(in: content, range: range) {
                if m.numberOfRanges >= 2,
                   let r = Range(m.range(at: 1), in: content) {
                    let v = String(content[r])
                    out.append(Entity(
                        kind: .invoiceNumber,
                        value: v,
                        normalizedValue: v.uppercased(),
                        sourceObjectID: object.id,
                        confidence: .high
                    ))
                }
            }
        }

        return out
    }
}
