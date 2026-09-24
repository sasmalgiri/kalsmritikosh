//
//  AbsentSubjectGate.swift
//  Kalsmritikosh
//
//  FOUND BY THE OWNER'S OWN ARCHIVE, 2026-09-24. The answer harness asked a
//  control question about a randomly generated reference — "What was decided in
//  Case No. 74287301-ZQX?" — that cannot exist in any archive. The app returned
//  a 1,159-character answer WITH THREE CITATIONS at confidence 0.40.
//
//  It was not inventing text out of nothing. The archive holds several
//  "Case SMOKE_TEST_001 · Investigation Report" documents, so retrieval matched
//  on the SHAPE of the question ("case", "decided", "investigation"), and the
//  composer wrote a fluent answer about SMOKE_TEST_001 while the user had asked
//  about 74287301-ZQX. That is worse than a hallucination: the citations are
//  real, so the answer looks verified. A reader is told, with sources, what was
//  decided in a case that does not exist.
//
//  WHY THE EXISTING GATES DID NOT CATCH IT. Two reasons, both in the RAG
//  fallback:
//
//    1. Refusal was detected by substring-matching the model's prose for two
//       English phrases ("don't have enough", "not enough"). The prompt asks the
//       model to emit the first one; here it simply did not — the chunks DID
//       contain enough about *a* case — so no refusal was ever signalled.
//    2. Even when the phrase appears, `refused: refusedShape && citations.isEmpty`
//       let any non-empty citation list override it. Citations prove passages
//       were RETRIEVED, never that they ANSWER the question asked.
//
//  Neither gate asks the one question that settles it: DOES THE THING THE USER
//  NAMED EXIST IN THIS LEDGER? That is deterministic, cheap, and exactly the
//  product's stated contract — refuse rather than guess.
//
//  WHAT THIS GATE DOES, AND ITS DELIBERATE NARROWNESS. It fires only when the
//  question names an IDENTIFIER-SHAPED token — something with digits, of the
//  kind that denotes one specific thing (a case number, a patent number, an
//  invoice reference) — and that token appears NOWHERE in the ledger. Then the
//  answer is a verified not-found that names the missing identifier.
//
//  It deliberately does NOT fire for ordinary prose questions. "What did we
//  decide about the roof?" names no identifier, so this gate is silent and the
//  normal evidence path applies. A gate that refused whenever retrieval looked
//  weak would suppress good answers; this one only refuses when the user asked
//  about a specific thing the archive has never heard of, which is the case
//  where an answer cannot be about what was asked.
//
//  Deterministic: no model call, one indexed query per candidate token.
//

import Foundation
import os

public struct AbsentSubjectGate: Sendable {

    /// An identifier the question names that the ledger has never seen.
    public struct Absence: Sendable, Equatable {
        /// As the user wrote it, so the refusal can quote them back.
        public let token: String
        /// The identifiers the ledger DOES hold, for "did you mean" honesty.
        /// Bounded — a list of hundreds is not help.
        public let nearestKnown: [String]
    }

    /// Tokens worth checking: they carry at least one digit and at least one
    /// alphanumeric run of length ≥ 4, which is what distinguishes a reference
    /// from ordinary words and from small numbers like "3 documents" or a year.
    ///
    /// Years are excluded explicitly. "What happened in 2024?" names a date,
    /// not a subject, and a ledger with no 2024 facts should answer "nothing in
    /// 2024" through the timeline lane — not refuse as though 2024 were an
    /// unknown case number.
    nonisolated static func candidateTokens(in question: String) -> [String] {
        let raw = question.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "/" })
            .map(String.init)
        var out: [String] = []
        for t in raw {
            let clean = t.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
            guard clean.count >= 4 else { continue }
            guard clean.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
            // A bare 4-digit year is a date, not an identifier.
            if clean.count == 4, let y = Int(clean), y >= 1800, y <= 2200 { continue }
            // Pure small integers are quantities, not references.
            if Int(clean) != nil, clean.count <= 4 { continue }
            // A WRITTEN DATE is not a missing subject. Measured over-fire: the
            // first version admitted "2024-05-21" and "21/05/2024", so
            // "What happened on 2024-05-21?" would have been REFUSED — on an
            // archive full of facts dated that very day, because dates are
            // stored as epoch numbers and never as that string. Date questions
            // are core to this product; suppressing them would have been a
            // worse regression than the fabrication this gate fixes.
            if isDateShaped(clean) { continue }
            // A CALENDAR PERIOD ("Q3-2024", "FY2024", "H1/2025") is a date
            // range, same reasoning.
            if isPeriodShaped(clean) { continue }
            // An identifier's digits come in a RUN. "COVID-19" and "MP3-320"
            // are names with a couple of digits attached, not references, and
            // admitting them meant refusing any question that mentioned one.
            guard longestDigitRun(clean) >= 4 else { continue }
            out.append(clean)
        }
        return out
    }

    /// yyyy-mm-dd, dd/mm/yyyy, dd-mm-yy, yyyy/mm/dd — the written forms.
    nonisolated static func isDateShaped(_ s: String) -> Bool {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return false }
        let nums = parts.compactMap(Int.init)
        // One component must be a plausible year and the other two must fit a
        // day/month. That admits both orderings without guessing the locale.
        let hasYear = nums.contains { $0 >= 1800 && $0 <= 2200 }
            || parts.contains { $0.count == 2 }
        let smallOnes = nums.filter { $0 >= 1 && $0 <= 31 }.count
        return hasYear && smallOnes >= 2
    }

    /// "Q3-2024", "FY2024", "H1/2025": a short alpha marker plus a year.
    ///
    /// Shape: 1–2 leading letters, then at most one extra digit, then a
    /// plausible 4-digit year. The alpha run is capped at TWO so a real
    /// reference prefix survives — "INV-2024-0093" has three letters and is
    /// admitted, which is the distinction that matters.
    nonisolated static func isPeriodShaped(_ s: String) -> Bool {
        let stripped = s.lowercased().filter { $0.isLetter || $0.isNumber }
        let letters = stripped.prefix { $0.isLetter }
        guard (1...2).contains(letters.count) else { return false }
        let rest = String(stripped.dropFirst(letters.count))
        guard rest.count >= 4, rest.allSatisfy(\.isNumber) else { return false }
        guard let year = Int(rest.suffix(4)), year >= 1800, year <= 2200 else { return false }
        // At most one digit may precede the year ("Q3", "H1"); more than that
        // is a reference, not a quarter.
        return rest.count - 4 <= 1
    }

    nonisolated static func longestDigitRun(_ s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            if ch.isNumber { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }

    /// Check the question's identifiers against the ledger.
    ///
    /// Returns nil when the question names no identifier, or when every
    /// identifier it names IS present — in both cases the ordinary answer path
    /// must proceed untouched.
    public nonisolated static func absence(
        in question: String, database: Database
    ) async -> Absence? {
        let tokens = candidateTokens(in: question)
        guard !tokens.isEmpty else { return nil }

        for token in tokens {
            let needle = "%\(token.lowercased())%"
            // Three places an identifier can legitimately live. All indexed or
            // small; this is a gate, not a scan.
            let queries = [
                "SELECT 1 FROM entities WHERE merged_into IS NULL AND LOWER(value) LIKE ? LIMIT 1;",
                "SELECT 1 FROM generic_facts WHERE LOWER(value) LIKE ? OR LOWER(subject_label) LIKE ? LIMIT 1;",
                "SELECT 1 FROM chunks WHERE LOWER(text) LIKE ? LIMIT 1;",
            ]
            var found = false
            for (i, sql) in queries.enumerated() {
                let binds: [SQLValue] = i == 1 ? [.text(needle), .text(needle)] : [.text(needle)]
                // A query that FAILS must not be read as "absent". Refusing on a
                // broken probe would turn a database error into a confident
                // "this does not exist" — the same absence-as-fact defect one
                // layer up.
                guard let rows = try? await database.query(sql, binds) else {
                    KalsmritikoshLog.brain.error(
                        "AbsentSubjectGate: existence probe failed; declining to claim absence for \(token, privacy: .private)")
                    return nil
                }
                if !rows.isEmpty { found = true; break }
            }
            if !found {
                let known = await knownIdentifiers(database: database)
                KalsmritikoshLog.brain.info(
                    "AbsentSubjectGate: question names an identifier absent from the ledger — refusing rather than answering about a different subject")
                return Absence(token: token, nearestKnown: known)
            }
        }
        return nil
    }

    /// A few identifiers the ledger really holds, so the refusal can say what
    /// IS here instead of only what is not.
    private nonisolated static func knownIdentifiers(database: Database) async -> [String] {
        guard let rows = try? await database.query("""
        SELECT DISTINCT value FROM entities
        WHERE kind = 'identifierAnchor' AND merged_into IS NULL
        ORDER BY value LIMIT 5;
        """, []) else { return [] }
        return rows.compactMap { $0.string(0) }
    }

    /// The refusal, phrased so the user learns what happened and why.
    public nonisolated static func notFoundAnswer(
        for absence: Absence, intent: UserIntent
    ) -> VerifiedAnswer {
        var body = "There is nothing in your archive about “\(absence.token)”.\n\n"
        body += "That reference does not appear in any document here — not in the text, "
        body += "not as an extracted detail, and not as a subject. So there is no answer "
        body += "to give about it.\n\n"
        body += "This is a deliberate refusal, not a search that came back thin. Documents "
        body += "in your archive do discuss similar-looking things, and answering from those "
        body += "would have told you about a DIFFERENT subject while appearing to answer "
        body += "about “\(absence.token)” — with citations, which would have made the "
        body += "mistake look verified."
        if !absence.nearestKnown.isEmpty {
            body += "\n\nReferences your archive does hold include: "
            body += absence.nearestKnown.joined(separator: ", ") + "."
        }
        return VerifiedAnswer(
            body: body,
            answerText: body,
            intentKind: intent.kind.rawValue,
            citations: [],
            confidence: Confidence(0.0),
            contradictions: [],
            refused: true,
            refusalReason: "The question names “\(absence.token)”, which does not exist anywhere in the ledger.",
            report: nil,
            walkSteps: [],
            source: .ragFallback,
            reasoningTrace: nil
        )
    }
}
