//
//  OCRConfusionRepair.swift
//  Kalsmritikosh
//
//  Unified path IN-26 (owner 2026-11-22) — not tested yet.
//
//  Proposes the spellings a scanner may have meant: a value read from a scan can carry a glyph
//  confusion (O↔0, l↔1↔I, rn↔m, S↔5, B↔8, Z↔2). The proposals are NEVER stored on their own — a
//  repair is only kept when EXACTLY ONE proposal matches a name or number the ledger already holds
//  (an entity, an alias, or another document's typed field). Two or more matches means the scan is
//  ambiguous, and nothing is repaired. The value as scanned is always kept; the repair rides beside
//  it with a marker naming the swaps, so a reader can judge it.
//
//  Pure, deterministic, offline. Bounded: at most `maxPositions` confusable positions are varied, so
//  the candidate set stays small (≤ 2^maxPositions plus the rn/m variants).
//

import Foundation

public nonisolated enum OCRConfusionRepair {

    /// One-glyph swaps scanners make (both directions).
    static let singleSwaps: [Character: [Character]] = [
        "O": ["0"], "0": ["O"], "o": ["0"],
        "l": ["1", "I"], "1": ["l", "I"], "I": ["1", "l"],
        "S": ["5"], "5": ["S"],
        "B": ["8"], "8": ["B"],
        "Z": ["2"], "2": ["Z"],
    ]

    static let maxPositions = 6
    static let maxCandidates = 128

    public struct Candidate: Sendable, Hashable {
        public let value: String
        /// The swaps applied, e.g. "O→0,l→1".
        public let marker: String
    }

    /// Every alternative reading of `value` (excluding `value` itself), each with its marker.
    public static func candidates(for value: String) -> [Candidate] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 80 else { return [] }
        var out: [Candidate] = []
        var seen: Set<String> = [trimmed]

        // Single-glyph swaps over the first `maxPositions` confusable positions.
        let chars = Array(trimmed)
        let positions = chars.indices.filter { singleSwaps[chars[$0]] != nil }.prefix(maxPositions)
        var partial: [([Character], [String])] = [(chars, [])]
        for p in positions {
            var next: [([Character], [String])] = []
            for (c, swaps) in partial {
                next.append((c, swaps))
                for alt in singleSwaps[chars[p]] ?? [] {
                    var copy = c
                    copy[p] = alt
                    next.append((copy, swaps + ["\(chars[p])→\(alt)"]))
                }
                if next.count > maxCandidates { break }
            }
            partial = Array(next.prefix(maxCandidates))
        }
        for (c, swaps) in partial where !swaps.isEmpty {
            let s = String(c)
            if seen.insert(s).inserted { out.append(Candidate(value: s, marker: swaps.joined(separator: ","))) }
        }

        // rn ↔ m (two glyphs read as one, and the reverse).
        if trimmed.contains("rn") {
            let s = trimmed.replacingOccurrences(of: "rn", with: "m")
            if seen.insert(s).inserted { out.append(Candidate(value: s, marker: "rn→m")) }
        }
        if trimmed.contains("m") {
            let s = trimmed.replacingOccurrences(of: "m", with: "rn")
            if seen.insert(s).inserted { out.append(Candidate(value: s, marker: "m→rn")) }
        }
        return Array(out.prefix(maxCandidates))
    }

    /// The single repair to keep: the one candidate the ledger already knows. nil when none or several
    /// match (ambiguous scans are never repaired).
    public static func repair(_ value: String, known: (String) -> Bool) -> Candidate? {
        let hits = candidates(for: value).filter { known($0.value) }
        return hits.count == 1 ? hits[0] : nil
    }
}
