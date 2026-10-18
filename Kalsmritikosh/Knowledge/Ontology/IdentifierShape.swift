//
//  IdentifierShape.swift
//  Kalsmritikosh
//
//  What a reference looks like, and what a field that HOLDS a reference or a date is called —
//  shared by the absent-subject gate (is the thing the question names in the archive?), the
//  open-field extractor (is this "label" really a document title carrying a case number?) and
//  the fact schema (what shape does an unknown field's value have?).
//
//  FOUND BY THE CASE BENCH, 2026-10-18 (62,846 NTSB investigations, OSHA accident
//  investigations, US court decisions). Three defects shared one missing notion:
//   - "NTSB case ZZZ99ZZ999" was not recognised as a reference (no 4-digit run), so a question
//     about a case that does not exist was answered from other cases;
//   - the title line "NTSB SEA08LA057 — factual narrative" was read as the field
//     "ntsbsea08la057" with the value "factual narrative";
//   - "Inspection number(s): 306505215", "Docket No.: 92-5255" and "Event date: December 3,
//     2003" stayed plain text because no pack declares those fields, so no anchor was made
//     and no date answer could use them.
//
//  Deterministic, offline.
//

import Foundation

public enum IdentifierShape {

    /// Longest run of consecutive digits.
    public nonisolated static func longestDigitRun(_ s: String) -> Int {
        var best = 0, run = 0
        for ch in s {
            if ch.isNumber { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }

    /// Letter and digit runs alternating at least twice (L-D-L or D-L-D, separators ignored),
    /// with at least three digits, two letters and six characters: "MIA08MA051", "B737MAX".
    /// "COVID-19" and "MP3-320" alternate once; "iPhone15Pro" carries two digits.
    public nonisolated static func isInterleavedReference(_ s: String) -> Bool {
        let chars = s.filter { $0.isLetter || $0.isNumber }
        guard chars.count >= 6 else { return false }
        let digits = chars.filter(\.isNumber).count
        guard digits >= 3, chars.count - digits >= 2 else { return false }
        var runs = 0
        var lastIsDigit: Bool?
        for ch in chars where lastIsDigit != ch.isNumber {
            runs += 1
            lastIsDigit = ch.isNumber
        }
        return runs >= 3
    }

    /// A single token that reads as a reference: a run of four or more digits, or an
    /// interleaved letter-digit code.
    public nonisolated static func looksLikeReference(_ token: String) -> Bool {
        longestDigitRun(token) >= 4 || isInterleavedReference(token)
    }

    // MARK: - Field names

    /// Words that end a date field's name without being dates ("candidate", "mandate").
    nonisolated static let dateLookalikes: Set<String> = [
        "candidate", "mandate", "update", "validate", "accommodate", "consolidate",
        "liquidate", "inundate", "sedate", "predate", "postdate",
    ]

    /// Words ending in "id" that are not identifiers.
    nonisolated static let idLookalikes: Set<String> = [
        "invalid", "liquid", "humid", "candid", "splendid", "stupid", "orchid", "pyramid", "acid", "rigid",
    ]

    /// The value shape a field's NAME implies, for fields no domain pack declares.
    /// `field` is a normalized field id ("inspectionnumbers", "docketno", "eventdate").
    /// Returns nil when the name says nothing, so the caller keeps its default (text).
    public nonisolated static func shape(impliedByFieldName field: String) -> FactSchemaRegistry.ValueShape? {
        let f = field.lowercased()
        guard f.count >= 4 else { return nil }
        // Dates first: "dateandtime", "eventdate", "datereceived", "issuedates".
        if f.hasPrefix("date") || f.hasSuffix("dateandtime") { return .date }
        if f.hasSuffix("date") || f.hasSuffix("dates") {
            let stem = f.hasSuffix("dates") ? String(f.dropLast()) : f
            if !dateLookalikes.contains(where: { stem.hasSuffix($0) }) { return .date }
        }
        // References: "...number(s)", "...no(s)" after a consonant ("docketno", "rollno" —
        // not "casino", "piano"), "...id" in a name of six or more ("containerid" — not
        // "paid", "valid"), and the words a reference is filed under.
        if f.hasSuffix("number") || f.hasSuffix("numbers") { return .identifier }
        for suffix in ["no", "nos"] where f.hasSuffix(suffix) {
            let before = f.dropLast(suffix.count).last
            if let b = before, !"aeiou".contains(b) { return .identifier }
        }
        if f.hasSuffix("id"), f.count >= 6, let b = f.dropLast(2).last, !"aeiou".contains(b),
           !idLookalikes.contains(where: { f.hasSuffix($0) }) { return .identifier }
        if ["registration", "docket", "reference", "referenceno", "ref", "serial", "accession"].contains(f) {
            return .identifier
        }
        return nil
    }
}
