//
//  FactValuePlausibility.swift
//  Kalsmritikosh
//
//  Topic-Ledger Rebuild U4 (owner rule 1 hygiene, 2026-09-17) — a value gate that
//  keeps extraction noise out of the ledger. The live audit found `amount` full of
//  junk fragments ("rs,", "$0", "$1", "Rs9") — currency symbols with no real
//  magnitude. This rejects those deterministically at the write path, so a fact is
//  stored only when its value is substantive. Pure; conservative (it rejects only
//  clearly-empty/degenerate values, never a plausible one).
//

import Foundation

public enum FactValuePlausibility {

    /// Monetary field ids whose value must carry a real magnitude (≥ 2 digits) —
    /// so "$0" / "$1" / "rs," can't masquerade as an amount.
    static let monetaryFields: Set<String> = [
        "amount", "fee", "cost", "price", "salary", "consideration", "balance", "payment",
    ]

    /// Whether a (field, value) is substantive enough to store.
    public nonisolated static func isAcceptable(field: String, value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 2 else { return false }                 // "", "a", "$" — not a fact
        // Must carry at least one letter or digit (not pure punctuation like "-" or "=").
        guard v.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        let f = field.lowercased()
        if monetaryFields.contains(where: { f.contains($0) }) {
            // A real amount needs a magnitude: at least two digits somewhere
            // ("$27", "5,00,000") — this drops "rs,", "$0", "$1", "Rs9".
            let digitCount = v.filter(\.isNumber).count
            return digitCount >= 2
        }
        return true
    }
}
