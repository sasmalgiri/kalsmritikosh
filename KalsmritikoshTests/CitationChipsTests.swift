//
//  CitationChipsTests.swift
//  Kalsmritikosh Tests
//
//  §1.3 — citation chips open at the quoted passage. The locator must find a
//  normalised snippet inside raw source text of any shape, map the hit back
//  to the exact UTF-16 range, and fail honestly (nil) when the quote is absent.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§1.3 — citation chips open at the quoted passage")
struct CitationChipsTests {

    private func text(_ hay: String, _ r: NSRange?) -> String? {
        guard let r else { return nil }
        return (hay as NSString).substring(with: r)
    }

    @Test("Whitespace and case differences between snippet and raw file do not defeat the match")
    func whitespaceTolerant() {
        let raw = "Dear Sir,\r\n\r\nWe have   prepared a DRAFT of the\n amendment in claims for your review.\n"
        let quote = "we have prepared a draft of the amendment in claims"
        let hit = CitedPassageLocator.locate(quote, in: raw)
        #expect(text(raw, hit) == "We have   prepared a DRAFT of the\n amendment in claims")
    }

    @Test("An ellipsis-stitched excerpt matches on its longest segment")
    func ellipsisExcerpt() {
        let raw = "Header line. The patent was granted on 12 March 2024 under the Patents Act. Footer."
        let quote = "…The patent was granted on 12 March 2024…"
        #expect(text(raw, CitedPassageLocator.locate(quote, in: raw)) == "The patent was granted on 12 March 2024")
    }

    @Test("A long quote whose tail differs still lands on its leading prefix")
    func prefixFallback() {
        let raw = "Invoice 4471 issued to Acme Industries Private Limited for consulting services rendered."
        let quote = "Invoice 4471 issued to Acme Industries Private Limited for consulting services rendered in full, see annexure B attached herewith"
        let hit = CitedPassageLocator.locate(quote, in: raw)
        #expect(text(raw, hit)?.hasPrefix("Invoice 4471 issued to Acme") == true)
    }

    @Test("Non-ASCII text maps back to the exact UTF-16 range")
    func unicodeMapping() {
        let raw = "Résumé — Ångström Łukasz 🙂 worked at Société Générale in Paris."
        let quote = "worked at société générale"
        #expect(text(raw, CitedPassageLocator.locate(quote, in: raw)) == "worked at Société Générale")
    }

    @Test("Honest failure: an absent quote or a too-short probe returns nil (the document opens un-highlighted)")
    func honestFailure() {
        let raw = "Minutes of meeting held on Monday."
        #expect(CitedPassageLocator.locate("the patent was granted", in: raw) == nil)
        #expect(CitedPassageLocator.locate("Monday", in: raw) == nil, "below the minimum probe length")
        #expect(CitedPassageLocator.locate("anything at all here", in: "") == nil)
    }

    @Test("One chip per source, in first-citation order")
    func distinctSources() {
        let a = UUID(), b = UUID()
        let cites = [
            VerifiedAnswer.Citation(objectID: a, snippet: "first a"),
            VerifiedAnswer.Citation(objectID: b, snippet: "first b"),
            VerifiedAnswer.Citation(objectID: a, snippet: "second a"),
        ]
        let chips = CitationChips.distinctSources(cites)
        #expect(chips.map(\.objectID) == [a, b])
        #expect(chips.first?.snippet == "first a", "the chip opens at the source's first quoted passage")
    }
}
