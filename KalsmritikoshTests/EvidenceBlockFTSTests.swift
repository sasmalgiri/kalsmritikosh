//
//  EvidenceBlockFTSTests.swift
//  KalsmritikoshTests
//
//  A6.1 — EvidenceStore.ftsQuery sanitizes free text into a safe FTS5 MATCH
//  expression (quoted tokens, ANDed) so user punctuation can't cause a syntax
//  error. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EvidenceBlockFTSTests {

    @Test func tokensAreQuotedAndAnded() {
        #expect(EvidenceStore.ftsQuery("invoice payment") == "\"invoice\" \"payment\"")
    }

    @Test func punctuationIsStrippedNotPassedToFTS() {
        // Quotes / parens / operators would break a raw FTS5 MATCH.
        let q = EvidenceStore.ftsQuery(#"amount: "1,200" (USD) OR paid?"#)
        #expect(!q.contains("("))
        #expect(!q.contains(":"))
        #expect(q.contains("\"amount\""))
        #expect(q.contains("\"1\"") || q.contains("\"200\"") || q.contains("\"usd\""))
    }

    @Test func singleCharTokensDropped() {
        // 2-char minimum avoids noise like "a"/"of" fragments.
        #expect(EvidenceStore.ftsQuery("a b contract") == "\"contract\"")
    }

    @Test func emptyOrPunctuationOnlyYieldsEmpty() {
        #expect(EvidenceStore.ftsQuery("   ") == "")
        #expect(EvidenceStore.ftsQuery("!!! ??? ...") == "")
    }
}
