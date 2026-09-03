//
//  FTSQuerySanitizerTests.swift
//  KalsmritikoshTests
//
//  V1.1 U2.5 — the sanitizer turns a raw punctuated question into a SAFE FTS5
//  MATCH expression: quoted terms, OR-joined, no operator ever leaks. This is
//  what makes the keyword layer stop dying silently on the identifier questions
//  the product is named for (task #40).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V1.1 U2.5 — FTSQuerySanitizer")
struct FTSQuerySanitizerTests {

    @Test("A punctuated identifier question sanitizes to quoted OR-terms carrying the number")
    func punctuatedIdentifierQuestion() {
        let out = FTSQuerySanitizer.sanitize("What is Patent No. 555489?")
        #expect(out.contains("\"555489\""), "the identifier must survive: \(out)")
        #expect(out.contains("\"patent\""))
        #expect(out.contains(" OR "), "recall-oriented OR join")
        // No raw FTS5 syntax leaks — no bare punctuation outside the quoted terms.
        #expect(!out.contains("?"))
        #expect(!out.contains("."))
    }

    @Test("FTS5 operator / punctuation input can never produce a syntax error — every token is quoted")
    func operatorsCannotLeak() {
        // Characters FTS5 treats as syntax: quotes, parens, colon, star, minus, near.
        let nasty = "\"NEAR\" (foo* -bar) : baz^2 AND 555-489"
        let out = FTSQuerySanitizer.sanitize(nasty)
        // Result is a sequence of double-quoted tokens joined by OR — nothing else.
        let terms = out.components(separatedBy: " OR ")
        for term in terms {
            #expect(term.hasPrefix("\"") && term.hasSuffix("\""), "unquoted term leaked: \(term)")
        }
        #expect(out.contains("\"555\"") && out.contains("\"489\""), "digits survive as separate tokens")
    }

    @Test("Empty / single-char / punctuation-only input → empty (no raw pass-through, no match-everything)")
    func degenerateInputs() {
        #expect(FTSQuerySanitizer.sanitize("") == "")
        #expect(FTSQuerySanitizer.sanitize("   ...?!  ") == "")
        #expect(FTSQuerySanitizer.sanitize("a b c") == "", "single-char noise tokens are dropped")
        // A short all-numeric token is KEPT (a year / id fragment).
        #expect(FTSQuerySanitizer.sanitize("2024") == "\"2024\"")
    }

    @Test("Deterministic — same input yields the same expression")
    func deterministic() {
        let q = "Timeline of the patent 555489 filed in 2023"
        #expect(FTSQuerySanitizer.sanitize(q) == FTSQuerySanitizer.sanitize(q))
    }
}
