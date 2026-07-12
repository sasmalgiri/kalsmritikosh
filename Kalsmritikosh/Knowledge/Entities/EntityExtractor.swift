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
