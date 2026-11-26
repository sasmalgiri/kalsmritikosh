//
//  WorkplaceInvestigationTests.swift
//  KalsmritikoshTests
//
//  Persona studio exemplar #1 — the workplace investigation must follow the
//  real-life stages and its report must match the recognized hardcopy format.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Workplace investigation studio")
struct WorkplaceInvestigationTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stages follow the real-life order and complete on real conditions")
    func stages() {
        var w = WorkplaceInvestigation(title: "x", now: t0)
        #expect(WorkplaceInvestigation.Stage.allCases.map(\.title) ==
                ["Mandate", "Allegations", "Evidence", "Credibility", "Findings", "Report"])
        #expect(!w.isComplete(.mandate))
        w.mandate = "Determine whether…"; w.investigator = "A"
        #expect(w.isComplete(.mandate))
        // Findings complete only when EVERY allegation is classified AND reasoned (final brief §3.6).
        w.allegations = [WIAllegation(question: "Did X…?")]
        #expect(!w.isComplete(.findings))
        w.allegations[0].finding = .substantiated
        #expect(!w.isComplete(.findings))              // no standard, no reasoning, no support, no response
        w.standardOfProof = .balanceOfProbabilities
        w.allegations[0].reasoning = "Because the statements show it."
        w.evidence = [WIEvidence(descriptionText: "Statements", source: "s.pdf")]
        w.allegations[0].supportingEvidence = [w.evidence[0].id]
        w.allegations[0].contraryAndMitigation = "Respondent's explanation weighed against the statements; no mitigation offered."
        #expect(!w.isComplete(.findings))              // the allegation was never put to the respondent
        w.allegations[0].response = .responded
        #expect(w.isComplete(.findings))
        // An unsubstantiated finding needs reasoning but no supporting evidence or response.
        var u = WIAllegation(question: "Did Y…?"); u.finding = .unsubstantiated; u.reasoning = "No record supports it."
        #expect(u.findingBlockers.isEmpty)
        // Credibility may be marked not applicable for a documentary case, with a reason.
        #expect(!w.isComplete(.credibility))
        w.credibilityNotApplicable = "Documentary case: no witness accounts were taken."
        #expect(w.isComplete(.credibility))
        // The chosen standard is the one printed.
        w.standardOfProof = .preponderance
        let md = WIReportRenderer.markdown(w, generatedAt: t0)
        #expect(md.contains("**Standard of proof:** Preponderance of the evidence") && !md.contains("Balance of probabilities."))
        #expect(md.contains("not a finding that the complaint was false"))
        // Report gate = procedural fairness confirmed.
        #expect(!w.isComplete(.report))
        w.noticeGiven = true; w.opportunityToRespond = true
        #expect(w.isComplete(.report))
    }

    @Test("The report matches the recognized hardcopy structure, in order")
    func hardcopyFormat() {
        let md = WIReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        let sections = ["1. Executive summary", "2. Mandate", "3. Parties", "4. Allegations",
                        "5. Methodology", "6. Evidence considered", "7. Credibility assessment",
                        "8. Findings (balance of probabilities)", "9. Recommendations", "10. Procedural fairness"]
        var last = md.startIndex
        for s in sections {
            let r = md.range(of: s, range: last..<md.endIndex)
            #expect(r != nil, "missing or out-of-order section: \(s)")
            if let r { last = r.upperBound }
        }
        // The professional essentials.
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))            // disclaimer leads
        #expect(md.contains("Standard of proof:** Balance of probabilities"))
        #expect(md.contains("**Finding: Substantiated**"))             // classified findings
        #expect(md.contains("Inconclusive"))
        #expect(md.contains("because"))                                // "because X, supported by Y"
        #expect(md.contains("Notice of the allegations given to the respondent: **Yes**"))
    }

    @Test("Recommendations are omitted when the mandate does not authorise them")
    func mandateGatesRecommendations() {
        var w = WorkplaceInvestigation.sample(now: t0)
        w.recommendationsAuthorised = false
        let md = WIReportRenderer.markdown(w, generatedAt: t0)
        #expect(md.contains("the mandate does not authorise them"))
        #expect(!md.contains("1. Refer the substantiated finding"))    // the list itself is withheld
    }

    @Test("A whole investigation survives a JSON round-trip (persistence)")
    func codable() throws {
        let original = [WorkplaceInvestigation.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([WorkplaceInvestigation].self, from: data) == original)
    }
}
