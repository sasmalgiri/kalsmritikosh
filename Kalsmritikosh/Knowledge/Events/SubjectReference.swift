//
//  SubjectReference.swift
//  Kalsmritikosh
//
//  Candidate UI run (2026-11-02, A4): "Conflicting dates for "Invoice issued"" paired invoice 401
//  with invoice 432 — two different invoices, not one invoice dated twice. Event titles are
//  generic ("Invoice issued"), so a title alone never says WHICH invoice, contract or order an
//  event is about. This reads the identifier a source gives its business subject ("Invoice No.
//  432", "contract #A-12", "PO 5531") so the contradiction detector can require the SAME
//  identified subject on both sides before it records a conflict.
//
//  Pure, deterministic, no model. Format-agnostic: it reads the normalized text only. The noun
//  family follows the event KIND (an invoice event is about an invoice), never the file type.
//

import Foundation
import os

public nonisolated enum SubjectReference {
    /// The event attribute that carries the normalized reference ("invoice 432").
    public static let attributeKey = "subjectRef"

    /// The noun family that names an identified subject for an event kind; nil when the kind has
    /// no identified document (a meeting, an e-mail) — such events keep title-only grouping.
    static func family(for kind: Event.Kind) -> (canonical: String, pattern: String)? {
        switch kind {
        case .invoiceIssued, .invoicePaid:
            return ("invoice", #"invoice|inv|bill"#)
        case .contractSigned, .contractModified:
            return ("contract", #"contract|agreement|amendment|addendum"#)
        case .deliveryDelayed, .deliveryCompleted:
            return ("order", #"purchase\s+order|order|po|shipment|consignment"#)
        default:
            return nil
        }
    }

    /// The reference an event's source gives its subject, normalized ("invoice 432"); nil when the
    /// source names none, or names several and none sits in the sentence that states the event.
    ///
    /// - Parameters:
    ///   - kind: the event kind (selects the noun family).
    ///   - marker: the phrase the event was read from, when known — the identifier in that
    ///     sentence wins over others elsewhere in the document.
    ///   - content: the source's normalized text.
    public static func reference(for kind: Event.Kind, marker: String?, in content: String) -> String? {
        guard let family = family(for: kind) else { return nil }
        if let marker, !marker.isEmpty {
            let sentences = content.components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            let local = Set(sentences
                .filter { $0.range(of: marker, options: .caseInsensitive) != nil }
                .flatMap { identifiers(family.pattern, in: $0) })
            if local.count == 1, let only = local.first { return "\(family.canonical) \(only)" }
            if local.count > 1 { return nil }                      // ambiguous at the event itself
        }
        let all = Set(identifiers(family.pattern, in: content))
        guard all.count == 1, let only = all.first else { return nil }
        return "\(family.canonical) \(only)"
    }

    /// The identifier a precomputed event carries, if any.
    public static func reference(of event: Event) -> String? {
        guard case .string(let ref)? = event.attributes[attributeKey]?.value, !ref.isEmpty else { return nil }
        return ref
    }

    /// Normalized identifiers following a family noun: "Invoice No. 432" → "432", "contract #A-12"
    /// → "a-12". A bare number needs three or more characters ("order 5 units" is a quantity), and
    /// a date or a year is never an identifier.
    static func identifiers(_ nounPattern: String, in text: String) -> [String] {
        let pattern = #"\b(?:"# + nounPattern
            + #")\b\.?\s*((?:no|nr|num|number|ref|reference|id)\b\.?|#)?\s*[:#]?\s*([a-z]{0,4}[-/]?\d[a-z0-9]*(?:[-/][a-z0-9]+)*)"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            KalsmritikoshLog.knowledge.error("SubjectReference: identifier pattern failed to compile")
            return []
        }
        let ns = text as NSString
        var out: [String] = []
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let qualified = m.range(at: 1).location != NSNotFound
            let id = ns.substring(with: m.range(at: 2)).lowercased()
            if isDateLike(id) { continue }
            if !qualified && id.count < 3 { continue }
            out.append(id)
        }
        return out
    }

    /// "2024", "2024-05-30", "30/05/2024" — dates, not identifiers.
    private static func isDateLike(_ s: String) -> Bool {
        s.range(of: #"^(19|20)\d{2}([-/]\d{1,2}){0,2}$"#, options: .regularExpression) != nil
            || s.range(of: #"^\d{1,2}[-/]\d{1,2}[-/]\d{2,4}$"#, options: .regularExpression) != nil
    }
}
