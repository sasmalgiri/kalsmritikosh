//
//  CanonicalFactComparator.swift
//  Kalsmritikosh
//
//  CLM-003 — canonical fact comparison for contradiction detection. Two facts about the
//  SAME subject + field contradict only when their CANONICAL values genuinely differ.
//  Comparing raw strings produces false positives ("₹3,800" vs "Rs 3800"; "12/01/2024" vs
//  "12 Jan 2024"; "Orchid Chemicals Ltd" vs "orchid chemicals"), which erode trust. This
//  normalizes by value shape before comparing, so only real conflicts are surfaced — and
//  both sides are always shown, never averaged away.
//
//  Deterministic, offline.
//

import Foundation

public struct CanonicalFactComparator: Sendable {
    public nonisolated init() {}

    public enum Relation: String, Sendable {
        case equivalent      // same canonical value — NOT a contradiction
        case contradictory   // same subject+field, different canonical value
        case incomparable    // different subject or field — no comparison
    }

    public nonisolated func compare(_ a: GenericFact, _ b: GenericFact) -> Relation {
        guard a.field == b.field, sameSubject(a, b) else { return .incomparable }
        let shape = FactSchemaRegistry.expectedShape(of: a.field)
        // Dates compare at the COARSER of the two precisions: "March 2024"
        // does not contradict "14 March 2024" — the month-only source simply
        // knows less (port-review item 6; canonical-string comparison flagged
        // exactly this as a false contradiction).
        if shape == .date,
           let equivalent = dateGrainEquivalent(a.value, b.value) {
            return equivalent ? .equivalent : .contradictory
        }
        return canonical(a.value, shape) == canonical(b.value, shape) ? .equivalent : .contradictory
    }

    /// Only genuine contradictions among a set of facts (same subject+field, different value).
    public nonisolated func contradictions(in facts: [GenericFact]) -> [(GenericFact, GenericFact)] {
        var out: [(GenericFact, GenericFact)] = []
        for i in 0..<facts.count {
            for j in (i + 1)..<facts.count where compare(facts[i], facts[j]) == .contradictory {
                out.append((facts[i], facts[j]))
            }
        }
        return out
    }

    // MARK: - Canonicalization

    nonisolated func sameSubject(_ a: GenericFact, _ b: GenericFact) -> Bool {
        if let ida = a.subjectID, let idb = b.subjectID { return ida == idb }
        return a.subjectLabel.localizedCaseInsensitiveCompare(b.subjectLabel) == .orderedSame
    }

    nonisolated func canonical(_ value: String, _ shape: FactSchemaRegistry.ValueShape) -> String {
        switch shape {
        case .money, .number:
            // Compare on digits only: "₹3,800" == "Rs 3800" == "3800".
            return value.filter { $0.isNumber }
        case .date:
            return canonicalDate(value)
        case .email, .identifier, .url, .phone:
            return value.lowercased().filter { !$0.isWhitespace }
        default:
            // Names/text: lowercase, drop punctuation/whitespace, and common org suffixes so
            // "Orchid Chemicals Ltd" == "orchid chemicals".
            let stripped = value.lowercased()
                .replacingOccurrences(of: "ltd", with: "")
                .replacingOccurrences(of: "pvt", with: "")
                .replacingOccurrences(of: "limited", with: "")
                .replacingOccurrences(of: "private", with: "")
                .replacingOccurrences(of: "inc", with: "")
            return stripped.filter { $0.isLetter || $0.isNumber }
        }
    }

    /// Normalize a date to yyyy-mm-ish digits so different formats compare equal when they
    /// denote the same day/period. Falls back to digit-only if unparseable.
    nonisolated func canonicalDate(_ value: String) -> String {
        let months = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                      "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]
        let lower = value.lowercased()
        // Try "12 Jan 2024" / "Jan 12 2024"
        var day: Int?; var month: Int?; var year: Int?
        for (name, num) in months where lower.contains(name) { month = num }
        let nums = lower.split { !$0.isNumber }.compactMap { Int($0) }
        for n in nums {
            if n > 1900 && n < 2100 { year = n }
            else if n <= 31 && day == nil { day = n }
            else if n <= 12 && month == nil { month = n }
        }
        if let y = year, let m = month {
            return String(format: "%04d-%02d-%02d", y, m, day ?? 0)
        }
        return value.filter { $0.isNumber }  // fallback: digits only
    }

    // MARK: - Precision-grain date comparison

    /// Parsed calendar components; `month`/`day` are nil when the value
    /// doesn't state them. Same token-assignment rules as `canonicalDate`
    /// (day before month for bare numbers) so the two paths never disagree
    /// on what "12/01/2024" means.
    nonisolated func dateComponents(_ value: String) -> (year: Int, month: Int?, day: Int?)? {
        let months = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                      "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]
        let lower = value.lowercased()
        var day: Int?; var month: Int?; var year: Int?
        for (name, num) in months where lower.contains(name) { month = num }
        let nums = lower.split { !$0.isNumber }.compactMap { Int($0) }
        for n in nums {
            if n > 1900 && n < 2100 { year = n }
            else if n <= 31 && day == nil { day = n }
            else if n <= 12 && month == nil { month = n }
        }
        guard let y = year else { return nil }
        return (y, month, day)
    }

    /// Grain-aware equivalence: compare only the components BOTH values
    /// state. "March 2024" ≡ "14 March 2024" (month grain); "14 March 2024"
    /// ≢ "20 March 2024" (day grain); "2024" ≡ "March 2024" (year grain).
    /// nil when either side has no parseable year — the caller falls back to
    /// canonical-string comparison.
    nonisolated func dateGrainEquivalent(_ a: String, _ b: String) -> Bool? {
        guard let ca = dateComponents(a), let cb = dateComponents(b) else { return nil }
        if ca.year != cb.year { return false }
        if let ma = ca.month, let mb = cb.month {
            if ma != mb { return false }
            if let da = ca.day, let db = cb.day, da != db { return false }
        }
        return true
    }
}
