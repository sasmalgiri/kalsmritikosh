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

    // MARK: Investigator workflow review 2026-10-30, I3

    private func twoByOne() -> (ACHAnalysis, ACHHypothesis, ACHHypothesis, ACHEvidence) {
        var a = ACHAnalysis(title: "x", now: t0)
        let h1 = ACHHypothesis(text: "Transcription error"), h2 = ACHHypothesis(text: "Deliberate change")
        a.hypotheses = [h1, h2]
        let e = ACHEvidence(text: "The dates differ")
        a.evidence = [e]
        return (a, h1, h2, e)
    }

    @Test("No ratings: two rivals and one unrated row establish no preference — not a 'leading' hypothesis")
    func unratedMatrixHasNoPreference() {
        let (a, h1, h2, e) = twoByOne()
        #expect(a.rating(e, h1) == nil && a.rating(e, h2) == nil, "an unrated cell is unassessed, not neutral")
        #expect(a.inconsistencyScore(h1) == 0 && a.inconsistencyScore(h2) == 0)
        #expect(a.preference == .noAssessment)
        #expect(a.leastInconsistent == nil, "a tie of zeros on nothing assessed must not single out the first hypothesis")
        #expect(a.preference.candidates.isEmpty)
        #expect(a.assessedCellCount == 0 && a.cellCount == 2 && a.unassessedCellCount == 2 && a.coverage == 0)
        #expect(a.preferenceStatement.contains("No preference is established"))
        #expect(a.isDiagnostic(e) == false)
    }

    @Test("Partial ratings: one rated cell does not make the unrated hypothesis the leader")
    func partialRatingsNoSolePreference() {
        var (a, h1, h2, e) = twoByOne()
        a.ratings[ACHAnalysis.key(e.id, h1.id)] = .inconsistent    // h1: 1 point; h2: unassessed → 0 by default
        #expect(a.ranking.first?.hypothesis.id == h2.id, "the raw ranking still orders by points")
        #expect(a.leastInconsistent == nil, "but an unrated hypothesis is not 'least inconsistent'")
        #expect(a.preference == .noDiscriminatingEvidence)
        #expect(a.isDiagnostic(e) == false, "a row with an unassessed cell is not diagnostic yet")
        #expect(a.isFullyAssessed(e) == false)
        #expect(a.assessedCellCount == 1 && a.unassessedCellCount == 1)
        #expect(a.preferenceStatement.contains("1 cell is still unassessed"))
        // Rate the second cell the same → fully assessed, still nothing discriminates.
        a.ratings[ACHAnalysis.key(e.id, h2.id)] = .inconsistent
        #expect(a.preference == .noDiscriminatingEvidence && a.leastInconsistent == nil)
        #expect(a.isFullyAssessed && a.isDiagnostic(e) == false)
    }

    @Test("Tied scores are presented together; a third hypothesis behind them does not break the tie")
    func tiesArePreserved() {
        var a = ACHAnalysis(title: "x", now: t0)
        let h1 = ACHHypothesis(text: "H1"), h2 = ACHHypothesis(text: "H2"), h3 = ACHHypothesis(text: "H3")
        a.hypotheses = [h1, h2, h3]
        let e = ACHEvidence(text: "e")
        a.evidence = [e]
        a.ratings[ACHAnalysis.key(e.id, h1.id)] = .consistent
        a.ratings[ACHAnalysis.key(e.id, h2.id)] = .neutral
        a.ratings[ACHAnalysis.key(e.id, h3.id)] = .veryInconsistent
        guard case .tied(let tied, let score) = a.preference else { Issue.record("expected a tie, got \(a.preference)"); return }
        #expect(Set(tied.map(\.id)) == [h1.id, h2.id] && score == 0)
        #expect(a.leastInconsistent == nil)
        #expect(a.preference.candidates.count == 2)
        #expect(a.preferenceStatement.contains("H1, H2 tie at 0 inconsistency points"))
        #expect(a.preferenceStatement.contains("no preference is established"))
        // Neutral and unassessed are different states: h2 is rated N, nothing is unassessed.
        #expect(a.rating(e, h2) == .neutral && a.unassessedCellCount == 0)
    }

    @Test("A genuine difference on assessed diagnostic evidence is explained from the ratings, without a probability")
    func leadingExplainedByRatings() {
        var (a, h1, h2, e) = twoByOne()
        a.ratings[ACHAnalysis.key(e.id, h1.id)] = .consistent
        a.ratings[ACHAnalysis.key(e.id, h2.id)] = .veryInconsistent
        guard case .leading(let h, let score, let runnerUp, let diagnostic) = a.preference else { Issue.record("expected leading, got \(a.preference)"); return }
        #expect(h.id == h1.id && score == 0 && runnerUp == 2 && diagnostic.map(\.id) == [e.id])
        #expect(a.leastInconsistent?.id == h1.id)
        let s = a.preferenceStatement
        #expect(s.contains("H1 has the fewest inconsistency points (0, against 2 for the next)"))
        #expect(s.contains("H1 C, H2 II"), "the explanation names the underlying ratings")
        #expect(s.contains("not a probability or a finding"))
        #expect(!s.contains("%"))
    }

    @Test("Unassessed and neutral are different states in the report; an uncited row is labelled the investigator's note, a cited one shows its citation")
    func reportDistinguishesStates() {
        var (a, h1, h2, e) = twoByOne()
        let cited = ACHEvidence(text: "Bank debit of ₹10,000 on 3 March", source: "statement p.2",
                                citation: StudioEvidenceRef(sourceVersionID: UUID(uuidString: "0A0B0C0D-0000-0000-0000-000000000001"), quote: "Debit 10,000.00"),
                                citationState: "verified")
        // §2 — an identifier that was not verified against the source is not a citation.
        let unchecked = ACHEvidence(text: "Refund credited", citation: StudioEvidenceRef(sourceVersionID: UUID(), quote: "Credit 2,000"), citationState: "unverified", citationDetail: "the quoted words are not in the cited source")
        a.evidence = [e, cited, unchecked]
        a.ratings[ACHAnalysis.key(e.id, h1.id)] = .neutral          // explicit N
        // e × h2 left unassessed; the cited row unrated entirely.
        let md = ACHReportRenderer.markdown(a, generatedAt: t0)
        #expect(md.contains("| The dates differ _(investigator's note — uncited)_ | N | — |"))
        #expect(md.contains("_(cited, verified: version 0A0B0C0D · “Debit 10,000.00” · statement p.2)_"))
        #expect(md.contains("_(investigator's note — citation unverified: the quoted words are not in the cited source)_"))
        #expect(cited.isCited && !unchecked.isCited && unchecked.hasCitation)
        #expect(md.contains("**Assessment coverage:** 1 of 6 cells rated; 5 unassessed (shown as —)."))
        #expect(md.contains("**What the ratings establish:** No assessed evidence distinguishes the hypotheses, so no preference is established. 5 cells are still unassessed."))
        #expect(md.contains("an unassessed cell counts for nothing and is not neutral"))
        #expect(cited.isCited && !e.isCited)
        // An older JSON without the citation key still decodes (citation nil).
        let old = #"{"id":"\#(UUID().uuidString)","text":"legacy","source":""}"#.data(using: .utf8)!
        #expect((try? JSONDecoder().decode(ACHEvidence.self, from: old))?.citation == nil)
    }
}
