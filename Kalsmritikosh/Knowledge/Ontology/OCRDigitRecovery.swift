//
//  OCRDigitRecovery.swift
//  Kalsmritikosh
//
//  Restores the digits of a numeric identifier that a SCANNER read as letters:
//  "Patent No. 7OO321" for "Patent No. 700321".
//
//  WHY THIS EXISTS. The strict identifier pattern requires digits, so on a
//  scanned page a mangled number matched NOTHING — and because nothing matched,
//  nothing was recorded. The value did not arrive wrong; it vanished, with no
//  trace that a labeled identifier had been seen at all. On a scanned grant
//  letter that is the whole answer to "what is the patent number?", so the
//  document silently held no fact.
//
//  WHY IT REFUSES FAR MORE OFTEN THAN IT CORRECTS. Substituting letters for
//  digits can MINT a number out of an ordinary word: "SOLO" → "5010", "BOSS" →
//  "8055", "GIGS" → "6165". A confidently wrong identifier in a ledger is
//  worse than a missing one, because it can be cited. So this is not a
//  spelling corrector: it only repairs a token that is ALREADY mostly digits
//  and whose every remaining character is a known scanner confusion. The
//  digit-majority gate is what kills the words above — they carry no digits to
//  recover from, so there is nothing here to repair and the answer is no.
//
//  WHAT THE CALLER MUST DO WITH THE RESULT. A recovered value is never
//  equivalent to a value read as written. The caller stores it at a reduced
//  confidence, marks it `.ocrCorrected`, and keeps the scanned form in
//  `rawMatch` — so a reader comparing the fact with its receipt sees "700321"
//  against "Patent No. 7OO321" and can judge the repair themselves. It is
//  offered as a candidate, never asserted as a clean reading.
//
//  Pure, deterministic, offline.
//

import Foundation

public enum OCRDigitRecovery {

    /// The substitutions this performs, and ONLY these: the digit/letter pairs
    /// that scanners actually confuse because the GLYPHS collide. Every entry
    /// is one-directional (letter → digit) because the input is a numeric
    /// identifier read as text. Deliberately short — "T"→"7" and "A"→"4" are
    /// plausible-sounding additions that would each widen what can be minted
    /// out of a word, so they are excluded until a real page demands them.
    public nonisolated static let confusions: [Character: Character] = [
        "O": "0", "o": "0", "Q": "0",
        "I": "1", "l": "1",
        "S": "5", "s": "5",
        "B": "8",
        "Z": "2", "z": "2",
        "G": "6"
    ]

    /// The regex character class matching a digit or any confusable letter,
    /// built FROM `confusions` so the two can never drift apart. A pattern
    /// listing letters the mapping does not know would match tokens this cannot
    /// repair; a mapping with letters the pattern omits would never be reached.
    public nonisolated static var candidateCharacterClass: String {
        let letters = confusions.keys.sorted().map(String.init).joined()
        return "[0-9\(letters)]"
    }

    /// At most this share of a token may be substituted — equivalently, AT
    /// LEAST HALF of it must be real digits. A token that is mostly letters is
    /// a word, and "recovering" it would be invention.
    ///
    /// The value is measured, not chosen: the noise fixture's own scan of
    /// "700321" is "7OO32l" (0→O twice AND 1→l), which is 3 substitutions in 6
    /// characters — exactly 0.5. A tighter gate refuses the very case this
    /// producer exists for, so the bound sits here and the WORD gate below does
    /// the work of rejecting prose. It can: any token of pure letters has no
    /// surviving digits at all, so its ratio is 1.0 whatever this is set to.
    public nonisolated static let maximumSubstitutionRatio = 0.5

    /// The fewest real digits a token must already carry to be repairable.
    /// This is the gate that refuses words outright: "SOLO" and "BOSS" have
    /// none, so there is no number here to restore.
    public nonisolated static let minimumSurvivingDigits = 2

    /// Identifier length bounds. Below 5 characters a "repair" is mostly guess
    /// (and no identifier this app extracts is that short); above 24 the token
    /// is not an identifier at all.
    public nonisolated static let lengthRange = 5...24

    /// The digits restored, or nil when this token must not be repaired.
    ///
    /// Returning nil is the expected outcome for anything that is not a scanned
    /// number, and it is NOT a failure: the strict reader handles clean values,
    /// and a token that fails these gates is one the app has no honest basis to
    /// rewrite.
    public nonisolated static func recover(_ raw: String) -> String? {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard lengthRange.contains(token.count) else { return nil }

        var restored = ""
        var substitutions = 0
        var survivingDigits = 0
        for character in token {
            if character.isNumber {
                restored.append(character)
                survivingDigits += 1
            } else if let digit = confusions[character] {
                restored.append(digit)
                substitutions += 1
            } else {
                // Neither a digit nor a known confusion. The token is not a
                // scanned number, so it is left alone entirely — a partial
                // repair would produce a value matching no real identifier.
                return nil
            }
        }

        // Nothing was substituted: this is a clean number and the strict
        // reader's business, not a recovery. Claiming it here would mark a
        // verbatim value as repaired.
        guard substitutions > 0 else { return nil }
        // THE WORD GATE. See `minimumSurvivingDigits`.
        guard survivingDigits >= minimumSurvivingDigits else { return nil }
        guard Double(substitutions) / Double(token.count) <= maximumSubstitutionRatio else { return nil }
        return restored
    }

    /// Whether `raw` would be repaired — for callers that need the decision
    /// without the value (guards, telemetry, tests).
    public nonisolated static func isRecoverable(_ raw: String) -> Bool {
        recover(raw) != nil
    }
}
