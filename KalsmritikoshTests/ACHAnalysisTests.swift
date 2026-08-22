//
//  ACHAnalysisTests.swift
//  KalsmritikoshTests
//
//  Analysis of Competing Hypotheses — the scoring is the technique, so lock it:
//  only I/II count against a hypothesis, ranking is fewest-inconsistencies-first,
//  diagnosticity means the evidence discriminates, and the report never claims a
//  computed verdict.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ACHAnalysis")
struct ACHAnalysisTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Only I/II count; ranking is fewest-inconsistencies-first")
    func scoringAndRanking() {
        var a = ACHAnalysis(title: "x", now: t0)
        let h1 = ACHHypothesis(text: "H1"), h2 = ACHHypothesis(text: "H2")
        a.hypotheses = [h1, h2]
        let e1 = ACHEvidence(text: "e1"), e2 = ACHEvidence(text: "e2")
        a.evidence = [e1, e2]
        // H1: consistent + very consistent → 0 inconsistency points.
        a.ratings[ACHAnalysis.key(e1.id, h1.id)] = .consistent
        a.ratings[ACHAnalysis.key(e2.id, h1.id)] = .veryConsistent
        // H2: inconsistent + very inconsistent → 1 + 2 = 3 points.
        a.ratings[ACHAnalysis.key(e1.id, h2.id)] = .inconsistent
        a.ratings[ACHAnalysis.key(e2.id, h2.id)] = .veryInconsistent

        #expect(a.inconsistencyScore(h1) == 0)
        #expect(a.inconsistencyScore(h2) == 3)
        #expect(a.ranking.first?.hypothesis.id == h1.id)   // fewest first
        #expect(a.ranking.last?.hypothesis.id == h2.id)
        #expect(a.leastInconsistent?.id == h1.id)
    }

    @Test("Diagnosticity = the evidence rates differently across hypotheses")
    func diagnosticity() {
        var a = ACHAnalysis(title: "x", now: t0)
        let h1 = ACHHypothesis(text: "H1"), h2 = ACHHypothesis(text: "H2")
        a.hypotheses = [h1, h2]
        let e = ACHEvidence(text: "e")
        a.evidence = [e]
        // Same rating on both → not diagnostic.
        a.ratings[ACHAnalysis.key(e.id, h1.id)] = .consistent
        a.ratings[ACHAnalysis.key(e.id, h2.id)] = .consistent
        #expect(a.isDiagnostic(e) == false)
        // Differing → diagnostic.
        a.ratings[ACHAnalysis.key(e.id, h2.id)] = .inconsistent
        #expect(a.isDiagnostic(e) == true)
    }

    @Test("The worked sample ranks misrepresentation last and transcription top")
    func sample() {
        let a = ACHAnalysis.sample(now: t0)
        #expect(a.isReady)
        #expect(a.ranking.first?.score == 0)                       // a fully-consistent hypothesis survives
        // The 'deliberate misrepresentation' hypothesis is heavily contradicted → highest score, ranked last.
        let last = try? #require(a.ranking.last)
        #expect(last?.hypothesis.text.contains("misrepresentation") == true)
        #expect((last?.score ?? 0) >= 4)
    }

    @Test("The report carries the matrix, scores, and the no-verdict caveat")
    func report() {
        let md = ACHReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.contains("Analysis of Competing Hypotheses"))
        #expect(md.contains("Consistency matrix"))
        #expect(md.contains("Inconsistency scores"))
        #expect(md.contains("Diagnostic"))
        #expect(md.lowercased().contains("does not compute a verdict"))
    }

    @Test("A whole analysis survives a JSON round-trip")
    func codable() throws {
        let original = [ACHAnalysis.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([ACHAnalysis].self, from: data) == original)
    }
}
