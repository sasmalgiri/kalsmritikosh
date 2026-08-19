//
//  SeeAlsoTests.swift
//  KalsmritikoshTests
//
//  COMPETITOR-DNA — the pure helpers behind the document-insights panel:
//  See-Also document ranking (best score per doc, source excluded) and the
//  Lightning-mode term extraction fallback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEE-ALSO — ranking + term extraction")
struct SeeAlsoTests {

    @Test("Ranking — best score per document, source excluded, top-N by score")
    func ranking() {
        let source = UUID(), a = UUID(), b = UUID(), c = UUID()
        let hits: [(objectID: KnowledgeObject.ID, score: Double)] = [
            (a, 0.4), (b, 0.9), (a, 0.7), (source, 0.99), (c, 0.5), (b, 0.2),
        ]
        let ranked = SeeAlso.rankDocuments(hits: hits, excluding: source, top: 2)
        #expect(ranked.map(\.objectID) == [b, a], "b's best 0.9 beats a's best 0.7; source dropped")
        #expect(ranked.map(\.score) == [0.9, 0.7])
        #expect(SeeAlso.rankDocuments(hits: [], excluding: source, top: 3).isEmpty)
    }

    @Test("Term extraction — stopwords/short words/numbers dropped, distinct, longest first")
    func termExtraction() {
        let text = "The insurance premium for the Wellington property, policy 123456, " +
                   "was disputed by the underwriter and the premium was recalculated."
        let terms = SeeAlso.terms(from: text, max: 4)
        #expect(terms.count == 4)
        #expect(terms.contains("recalculated"))
        #expect(terms.contains("wellington"))
        #expect(!terms.contains("123456"), "pure numbers dropped")
        #expect(!terms.contains("the"), "stopwords dropped")
        #expect(Set(terms).count == terms.count, "distinct")
        // Longest-first ordering.
        #expect(terms == terms.sorted { $0.count > $1.count })
        #expect(SeeAlso.terms(from: "a an it 12 999").isEmpty)
    }
}
