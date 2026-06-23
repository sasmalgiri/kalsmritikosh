//
//  OntologyValidator.swift
//  Kalsmritikosh
//
//  G3.9 — validate a (FactType, slot-values JSON) pair against the
//  v1 Ontology before persisting. Returns a Verdict that the write
//  path interprets:
//    .ok                       — write as-is
//    .lowQuality(reasons)      — write, but mark confidence low; the
//                                 UI may flag the row as a "data quality
//                                 issue" so the user can correct it
//    .reject(reasons)          — refuse the write; surface to log
//
//  The validator is pure: no I/O, no actor state. Trivial to unit
//  test (and SmokeTest checks the boundary cases below).
//

import Foundation

public struct OntologyValidator: Sendable {
    public enum Verdict: Sendable, Equatable {
        case ok
        case lowQuality(reasons: [String])
        case reject(reasons: [String])
    }

    public nonisolated init() {}

    /// Validate a (type, slots) pair. The slots are decoded
    /// `AnyCodable.AnySendable` values keyed by slot name; the
    /// write-side serialises them to JSON.
    public nonisolated func validate(
        type: FactType,
        slots: [String: AnyCodable.AnySendable]
    ) -> Verdict {
        guard let schema = Ontology.schema(for: type) else {
            return .reject(reasons: ["Unknown FactType \(type.rawValue)"])
        }

        var lowQualityReasons: [String] = []

        // 1. Every present slot must be a recognized name on this type.
        let knownNames = Set(schema.slots.map(\.name))
        for present in slots.keys where !knownNames.contains(present) {
            lowQualityReasons.append("Unknown slot '\(present)' on \(type.rawValue)")
        }

        // 2. Required slots must be present + non-empty.
        for slot in schema.slots {
            let value = slots[slot.name]
            let isPresent = !isNullish(value)
            switch slot.cardinality {
            case .one:
                if !isPresent {
                    return .reject(reasons: ["Required slot '\(slot.name)' missing on \(type.rawValue)"])
                }
            case .oneOrMore:
                if !isPresent || !isCollectionNonEmpty(value) {
                    return .reject(reasons: ["Required collection slot '\(slot.name)' empty on \(type.rawValue)"])
                }
            case .zeroOrOne, .zeroOrMore:
                break
            }
        }

        // 3. Type compatibility on present slots. The slot extractor
        //    is expected to produce the right shape; mismatches are
        //    low-quality, not rejects (the data still goes in; the
        //    UI shows a warning).
        for slot in schema.slots {
            guard let value = slots[slot.name], !isNullish(value) else { continue }
            if !valueMatches(slot.type, value: value) {
                lowQualityReasons.append("Slot '\(slot.name)' value type doesn't match expected \(describe(slot.type))")
            }
        }

        return lowQualityReasons.isEmpty ? .ok : .lowQuality(reasons: lowQualityReasons)
    }

    // MARK: - Internals

    private nonisolated func isNullish(_ v: AnyCodable.AnySendable?) -> Bool {
        guard let v else { return true }
        if case .null = v { return true }
        if case .string(let s) = v, s.isEmpty { return true }
        return false
    }

    private nonisolated func isCollectionNonEmpty(_ v: AnyCodable.AnySendable?) -> Bool {
        guard let v else { return false }
        if case .array(let arr) = v { return !arr.isEmpty }
        return !isNullish(v)
    }

    private nonisolated func valueMatches(_ slotType: SlotType, value: AnyCodable.AnySendable) -> Bool {
        switch (slotType, value) {
        case (.string, .string): return true
        case (.integer, .int): return true
        case (.decimal, .double), (.decimal, .int): return true
        case (.bool, .bool): return true
        case (.date, .string(let s)):
            return ISO8601DateFormatter().date(from: s) != nil
        case (.reference(_), .string(let s)):
            // References are stored as UUID strings.
            return UUID(uuidString: s) != nil
        default:
            return false
        }
    }

    private nonisolated func describe(_ t: SlotType) -> String {
        switch t {
        case .string: return "string"
        case .integer: return "integer"
        case .decimal: return "decimal"
        case .date: return "date (ISO8601)"
        case .bool: return "bool"
        case .reference(let ft): return "reference(\(ft.rawValue))"
        }
    }
}
