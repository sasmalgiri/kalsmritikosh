//
//  ExtractionQualityRules.swift
//  Kalsmritikosh
//
//  Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet.
//  The remainder of the extraction review backlog (C-5, C-7, C-9):
//
//  C-7  FactValueNormalizer — write-time per-shape tidying of a pack's value
//       (whitespace, stray trailing punctuation, "/-" after an Indian amount,
//       mailto:/angle brackets on an e-mail, spaces around identifier
//       separators). The meaning never changes; a value that is empty after
//       tidying is dropped and counted.
//  C-9  StrictPackPolicy — when the document's class is known and a pack is
//       NOT one of that class's packs, the pack runs STRICT: a fact must come
//       with an explicit label in its matched text (bare values are dropped and
//       counted), and what survives keeps a reduced confidence. Classes that
//       legitimately mention anything (e-mail, notes, images, other) are never
//       strict. Packs stay additive.
//  C-5  ExtractionTelemetry — on-device counters for the Live tab: documents
//       read, documents with no facts, facts per document class, strict-pack
//       rejections and downgrades, empty values dropped. The share of subjects
//       whose field holds more than one value (>20 % = a rule defect) is
//       measured from the ledger by LiveMetrics.
//

import Foundation
import os

// MARK: - C-7

nonisolated enum FactValueNormalizer {
    /// The tidied value, or nil when nothing is left.
    static func normalize(_ value: String, shape: FactSchemaRegistry.ValueShape) -> String? {
        var v = value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trailing: Set<Character>
        switch shape {
        case .email:
            v = v.lowercased()
            if v.hasPrefix("mailto:") { v.removeFirst(7) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' "))
            trailing = [".", ",", ";", ":", ")"]
        case .url:
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' "))
            trailing = [".", ",", ";", ":", ")"]
        case .money, .number:
            if v.hasSuffix("/-") { v.removeLast(2) }
            trailing = [",", ";", ":", "."]
        case .identifier:
            v = v.replacingOccurrences(of: " / ", with: "/").replacingOccurrences(of: " - ", with: "-")
            trailing = [",", ";", ":", "."]
        case .phone:
            trailing = [",", ";", ":", "."]
        case .date:
            trailing = [",", ";", ":"]
        default:
            // Text keeps a final "." (abbreviations: "Ltd.", "Jr.").
            trailing = [",", ";", ":"]
        }
        while let last = v.last, trailing.contains(last) || last == " " { v.removeLast() }
        while let first = v.first, first == " " || first == "," || first == ";" { v.removeFirst() }
        return v.isEmpty ? nil : v
    }
}

// MARK: - C-9

nonisolated enum StrictPackPolicy {
    /// The packs that belong to a class. A class absent here is never strict.
    static let packsByClass: [DocumentClass: Set<DomainFactExtractor.PackRoot>] = [
        .legalDocument: [.patent, .legalCase, .contract, .property, .identityDocument],
        .certificate:   [.patent, .vitalRecords, .identityDocument, .research, .employment],
        .invoice:       [.transaction, .financialStatement],
        .receipt:       [.transaction, .financialStatement],
        .contract:      [.contract, .employment, .property, .transaction],
        .resume:        [.employment, .research, .identityDocument],
        .researchPaper: [.research, .patent, .medical],
    ]
    /// Confidence kept by a labelled fact from a pack that does not match the class.
    static let strictConfidenceFactor = 0.85

    static func isStrict(_ root: DomainFactExtractor.PackRoot, for docClass: DocumentClass?) -> Bool {
        guard let docClass, let own = packsByClass[docClass] else { return false }
        return !own.contains(root)
    }

    /// Whether the matched text carries an explicit label beyond the value itself (two or more letters
    /// left once the value is removed). A fact without a recorded match cannot show a label.
    static func hasExplicitLabel(_ fact: GenericFact) -> Bool {
        guard let raw = fact.rawMatch, !raw.isEmpty else { return false }
        let rest = raw.replacingOccurrences(of: fact.value, with: " ", options: .caseInsensitive)
        return rest.filter(\.isLetter).count >= 2
    }
}

// MARK: - C-5

/// Process-wide extraction counters (since launch). Lock-based so the synchronous extractor can record.
public nonisolated final class ExtractionTelemetry: @unchecked Sendable {
    public static let shared = ExtractionTelemetry()

    public struct Snapshot: Sendable, Equatable, Codable {   // Codable: Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet.
        public var documents = 0
        public var documentsWithNoFacts = 0
        public var factsByClass: [String: Int] = [:]
        public var strictRejected = 0
        public var strictDowngraded = 0
        public var emptyValuesDropped = 0
        public var valuesTidied = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    public func snapshot() -> Snapshot { lock.withLock { $0 } }

    func recordDocument(documentClass: DocumentClass?, facts: Int) {
        lock.withLock { s in
            s.documents += 1
            if facts == 0 { s.documentsWithNoFacts += 1 }
            s.factsByClass[documentClass?.rawValue ?? "unclassified", default: 0] += facts
        }
    }

    /// Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet. Add the totals kept from earlier launches (once).
    public func seed(_ base: Snapshot) {
        lock.withLock { s in
            s.documents += base.documents
            s.documentsWithNoFacts += base.documentsWithNoFacts
            for (k, v) in base.factsByClass { s.factsByClass[k, default: 0] += v }
            s.strictRejected += base.strictRejected
            s.strictDowngraded += base.strictDowngraded
            s.emptyValuesDropped += base.emptyValuesDropped
            s.valuesTidied += base.valuesTidied
        }
    }

    func recordPackPass(rejected: Int, downgraded: Int, emptied: Int, tidied: Int) {
        guard rejected + downgraded + emptied + tidied > 0 else { return }
        lock.withLock { s in
            s.strictRejected += rejected
            s.strictDowngraded += downgraded
            s.emptyValuesDropped += emptied
            s.valuesTidied += tidied
        }
    }
}
