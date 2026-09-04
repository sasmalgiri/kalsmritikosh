//
//  SubjectResolver.swift
//  Kalsmritikosh
//
//  P3-U0 (GO 2 REVISED) — Ask-path SUBJECT RESOLUTION: referents resolve
//  DETERMINISTICALLY before retrieval, and the answer's subject line is the
//  resolution's output — never retrieval bycatch. The owner witnessed the
//  old way live: a patent question's footer named résumé people and parse
//  ghosts ("Bill Delhi"). The law:
//
//    identifier in the question  → that anchor (exact canon match)
//    definite reference          → the field-kind's anchors: exactly one
//      ("the patent")              subject → resolve; several → list them,
//                                  NEVER guess; none → no charter
//    otherwise                   → no charter (footer omitted; retrieval
//                                  proceeds unscoped, as today)
//
//  The resolution rides the receipt; the footer renders "About: …" from the
//  charter or is OMITTED — the mined subjects-in-scope line is dead.
//

import Foundation

public struct ResolvedSubjectCharter: Sendable, Equatable {
    public enum Method: String, Sendable {
        case identifierInQuestion
        case definiteReference
        case ambiguous          // several subjects — listed, never guessed
        case none
    }
    public let method: Method
    /// The resolved anchors (primary first, then same-document siblings).
    public let anchors: [Entity]
    /// "About: Patent No. 555489 (Application 202331019665)" — or nil (omit).
    public let footerText: String?
    /// The receipt line: how resolution happened, in plain language.
    public let receiptLine: String
}

public enum SubjectResolver {

    /// Plain-language anchor labels (data, not code — RC-8 discipline).
    /// Primary rendering: "<label> <value>"; sibling: "(<label> <value>)".
    nonisolated static let anchorLabels: [String: String] = [
        "patentnumber":       "Patent No.",
        "applicationnumber":  "Application",
        "invoicenumber":      "Invoice",
        "contractnumber":     "Contract",
        "casenumber":         "Case",
        "registrationnumber": "Registration",
    ]

    /// Definite-reference nouns → anchor field family ("the patent" → its
    /// number anchor). Data, not code.
    nonisolated static let definiteReferences: [String: String] = [
        "patent":       "patentnumber",
        "application":  "applicationnumber",
        "invoice":      "invoicenumber",
        "contract":     "contractnumber",
        "case":         "casenumber",
        "registration": "registrationnumber",
    ]

    /// Resolve the question against the live anchor register. Deterministic:
    /// same question + same anchors → same charter, always.
    public nonisolated static func resolve(question: String, anchors: [Entity]) -> ResolvedSubjectCharter {
        guard !anchors.isEmpty else {
            return ResolvedSubjectCharter(method: .none, anchors: [], footerText: nil,
                                          receiptLine: "No subject resolved (no identifier anchors on file).")
        }
        let q = question.lowercased()

        // 1 — an identifier VALUE in the question resolves exactly.
        let digitTokens = q.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.contains(where: \.isNumber) }
        for token in digitTokens {
            if let hit = anchors.first(where: { canon($0) == token }) {
                let family = siblings(of: hit, in: anchors)
                return ResolvedSubjectCharter(
                    method: .identifierInQuestion, anchors: family,
                    footerText: footer(for: family),
                    receiptLine: "Subject resolved from the identifier in your question.")
            }
        }

        // 2 — a definite reference resolves through the field family.
        for (noun, field) in definiteReferences.sorted(by: { $0.key < $1.key }) {
            guard q.contains("the \(noun)") || q.contains("this \(noun)") else { continue }
            let candidates = anchors.filter { fieldID(of: $0) == field }
            if candidates.count == 1, let only = candidates.first {
                let family = siblings(of: only, in: anchors)
                return ResolvedSubjectCharter(
                    method: .definiteReference, anchors: family,
                    footerText: footer(for: family),
                    receiptLine: "Subject resolved: the one \(noun) on file.")
            }
            if candidates.count > 1 {
                // Several subjects — LIST them, never guess one.
                let sorted = candidates.sorted { canon($0) < canon($1) }
                let listed = sorted.compactMap { render($0) }.joined(separator: "; ")
                return ResolvedSubjectCharter(
                    method: .ambiguous, anchors: sorted,
                    footerText: listed.isEmpty ? nil : "About (\(candidates.count) \(noun)s on file): \(listed)",
                    receiptLine: "Your archive holds \(candidates.count) \(noun)s — say which one, or ask about each.")
            }
        }

        return ResolvedSubjectCharter(method: .none, anchors: [], footerText: nil,
                                      receiptLine: "No subject resolved (the question names no identifier or known reference).")
    }

    // MARK: - the pieces

    /// The anchor's identity key is "field|canon" in `normalized` (V3 law).
    nonisolated static func fieldID(of anchor: Entity) -> String {
        String(anchor.normalizedValue?.split(separator: "|").first ?? "")
    }
    nonisolated static func canon(_ anchor: Entity) -> String {
        anchor.normalizedValue?.split(separator: "|").dropFirst().joined(separator: "|") ?? ""
    }

    /// Same-document siblings: anchors born from the same source object join
    /// the charter (the grant letter's application number rides with its
    /// patent number). Primary first; siblings in field order; capped at 3.
    nonisolated static func siblings(of primary: Entity, in anchors: [Entity]) -> [Entity] {
        var family = [primary]
        let rest = anchors
            .filter { $0.id != primary.id && $0.sourceObjectID == primary.sourceObjectID }
            .sorted { fieldID(of: $0) < fieldID(of: $1) }
        family.append(contentsOf: rest.prefix(2))
        return family
    }

    nonisolated static func render(_ anchor: Entity) -> String? {
        guard let label = anchorLabels[fieldID(of: anchor)] else { return nil }
        let value = canon(anchor)
        return value.isEmpty ? nil : "\(label) \(value)"
    }

    /// "About: Patent No. 555489 (Application 202331019665)" — primary plain,
    /// siblings parenthesised; unknown fields are omitted rather than jargoned.
    nonisolated static func footer(for family: [Entity]) -> String? {
        guard let primary = family.first, let head = render(primary) else { return nil }
        let tail = family.dropFirst().compactMap { render($0) }.map { "(\($0))" }
        return "About: " + ([head] + tail).joined(separator: " ")
    }
}
