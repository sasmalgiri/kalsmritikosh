//
//  ConflictKind.swift
//  Kalsmritikosh
//
//  Owner request 2026-11-16 (AI conflict scaffolding): "There can be many kinds of reasons, conflicts and contradictions;
//  rules can't cover them all." The OPEN conflict taxonomy: a typed set of known kinds plus `other(label)`, where the AI
//  (or a later detector) names a kind this build has no case for with a short label of its own. It is stored as one
//  text value ("date_time", "other:alibi window"); a value this build does not know reads as `other` with that value as
//  its label, so older and newer data both load. Each kind maps onto the ledger's stored `Contradiction.Kind`.
//

import Foundation

public nonisolated enum ConflictKind: Hashable, Sendable, Codable, Identifiable {
    case dateTime
    case amountQuantity
    case count
    case identity
    case location
    case sequenceCausation
    case documentVsTestimony
    case statementVsRecords
    case internalInconsistency
    case omission
    case explanation
    case capability
    case other(String)

    /// Every named kind (the list the AI is given; `other` is offered separately, with its label).
    public static let known: [ConflictKind] = [.dateTime, .amountQuantity, .count, .identity, .location, .sequenceCausation,
                                                .documentVsTestimony, .statementVsRecords, .internalInconsistency, .omission,
                                                .explanation, .capability]

    /// The longest label an `other` kind keeps (a short name, not an explanation).
    public static let labelLimit = 40

    public var id: String { storageValue }

    /// The code of the kind ("other" for every other(label)).
    public var code: String {
        switch self {
        case .dateTime: return "date_time"
        case .amountQuantity: return "amount_quantity"
        case .count: return "count"
        case .identity: return "person_role_identity"
        case .location: return "place_location"
        case .sequenceCausation: return "sequence_causation"
        case .documentVsTestimony: return "document_vs_testimony"
        case .statementVsRecords: return "statement_vs_records"
        case .internalInconsistency: return "internal_inconsistency"
        case .omission: return "omission_missing_record"
        case .explanation: return "explanation_reason_motive"
        case .capability: return "capability_opportunity"
        case .other: return "other"
        }
    }

    /// What the kind covers, in plain words (shown in the filter and given to the AI as the meaning of the code).
    public var meaning: String {
        switch self {
        case .dateTime: return "two accounts give different dates or times for the same thing"
        case .amountQuantity: return "different amounts or quantities for the same thing"
        case .count: return "a different number of times, payments or items"
        case .identity: return "a different person, role or identity for the same act or position"
        case .location: return "a different place for the same thing"
        case .sequenceCausation: return "an order of events or a cause that cannot be true (A before B is impossible)"
        case .documentVsTestimony: return "a document says one thing and a person's account says another"
        case .statementVsRecords: return "a statement disagrees with records such as money records or structured data"
        case .internalInconsistency: return "one source contradicts itself"
        case .omission: return "something that should exist (a record, an entry, a payment) is not there"
        case .explanation: return "a reason, explanation or motive given does not fit what the documents show"
        case .capability: return "someone could not have been there or done it"
        case .other(let label): return label.isEmpty ? "another kind of conflict" : label
        }
    }

    public var displayName: String {
        switch self {
        case .dateTime: return "Date or time"
        case .amountQuantity: return "Amount or quantity"
        case .count: return "Count"
        case .identity: return "Person, role or identity"
        case .location: return "Place"
        case .sequenceCausation: return "Order or cause"
        case .documentVsTestimony: return "Document vs testimony"
        case .statementVsRecords: return "Statement vs records"
        case .internalInconsistency: return "Inconsistent within one source"
        case .omission: return "Missing record"
        case .explanation: return "Explanation, reason or motive"
        case .capability: return "Could not have been there or done it"
        case .other(let label): return label.isEmpty ? "Other" : "Other: \(label)"
        }
    }

    /// The label of an `other` kind (nil for a named kind).
    public var otherLabel: String? {
        if case .other(let l) = self { return l }
        return nil
    }

    /// The one text value it is stored as: the code, or "other:<label>".
    public var storageValue: String {
        if case .other(let l) = self { return l.isEmpty ? "other" : "other:" + l }
        return code
    }

    /// A kind from its code and, for `other`, its label. An unknown code is kept as `other` labelled with the code itself,
    /// so nothing written by a newer build is lost or refused.
    public init(code: String, label: String? = nil) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let k = Self.known.first(where: { $0.code == c }) { self = k; return }
        if c == "other" || c.isEmpty {
            self = .other(Self.cleanLabel(label ?? ""))
            return
        }
        self = .other(Self.cleanLabel(code))
    }

    /// The kind a stored value names ("date_time", "other:alibi window", or anything older or newer).
    public init(storageValue: String) {
        let s = storageValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("other:") {
            self = .other(Self.cleanLabel(String(s.dropFirst(6))))
        } else {
            self.init(code: s)
        }
    }

    /// A label kept short and on one line.
    public static func cleanLabel(_ s: String) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(one.prefix(labelLimit))
    }

    /// The ledger's stored kind (the open label is kept in the conflict's detail record).
    public var stored: Contradiction.Kind {
        switch self {
        case .dateTime: return .date
        case .amountQuantity: return .amount
        case .count: return .count
        case .identity: return .identity
        case .location: return .location
        case .sequenceCausation: return .sequence
        case .documentVsTestimony: return .documentVsTestimony
        case .statementVsRecords: return .statementVsRecords
        case .internalInconsistency: return .internalInconsistency
        case .omission: return .omission
        case .explanation: return .explanation
        case .capability: return .capability
        case .other: return .other
        }
    }

    /// The kind of a stored conflict that has no detail record (a rule finding or an older row).
    public static func of(_ c: Contradiction) -> ConflictKind {
        if let word = CaseContradictionFinder.kindLabel(of: c) {
            switch word {
            case "Amount", "Sentence": return .amountQuantity
            case "Date": return .dateTime
            case "Count": return .count
            case "Role", "Age": return .identity
            case "Account": return .documentVsTestimony
            default: break
            }
        }
        switch c.kind {
        case .date: return .dateTime
        case .amount, .payment: return .amountQuantity
        case .count: return .count
        case .identity, .signature: return .identity
        case .location: return .location
        case .sequence, .causation, .eventOccurrence: return .sequenceCausation
        case .testimony, .documentVsTestimony: return .documentVsTestimony
        case .statementVsRecords: return .statementVsRecords
        case .internalInconsistency: return .internalInconsistency
        case .omission: return .omission
        case .explanation: return .explanation
        case .capability: return .capability
        case .status, .documentVersion, .sentReceived, .other: return .other(c.kind == .other ? "" : c.kind.displayName)
        }
    }

    // MARK: Codable (one text value)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(storageValue: try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storageValue)
    }
}
