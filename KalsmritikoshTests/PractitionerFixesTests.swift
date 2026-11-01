//
//  PractitionerFixesTests.swift
//  KalsmritikoshTests
//
//  Blockers from the agent practitioner reviews of 2026-11-02 (docs/agent-reviews/practitioner-*.md).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Practitioner review fixes (2026-11-02)")
struct PractitionerFixesTests {

    @Test("A reading limit is never silent: documents beyond it and truncated events are stated in every job's limitations")
    func readingLimitStated() {
        let f = StudioCaseFacts(caseTitle: "c", parties: [], dates: [], amounts: [], identifiers: [], documents: [], events: [],
                                allFacts: [], documentsNotRead: 3, eventsTruncated: true)
        let l = JobText.withheldLimitation(0, facts: f)
        #expect(l.count == 2)
        #expect(l[0].hasPrefix("3 document(s) in this case are beyond the 5000-document reading limit"))
        #expect(l[1].contains("more than 50000 dated events"))
        #expect(JobText.withheldLimitation(0, facts: .empty).isEmpty)
        #expect(StudioCaseFacts.documentReadingLimit >= 5_000, "the old silent cap was 60 documents")
    }

    @Test("SIU: an external referral cannot complete without the contrary facts and innocent explanations; the report always prints them; an old saved referral still opens")
    func siuContraryFacts() throws {
        var r = SIUReferral.sample(now: Date(timeIntervalSince1970: 1_800_000_000))
        r.disposition = .referNICB; r.dispositionRationale = "Reasonable suspicion on the date of loss."
        r.indicatorsNotProofAcknowledged = true; r.goodFaithConfirmed = true; r.contraryFacts = nil
        #expect(!r.isComplete(.disposition), "external referral without contrary facts")
        #expect(SIUReportRenderer.markdown(r, generatedAt: Date()).contains("### Contrary facts and innocent explanations considered\n\n_Not recorded._"))
        r.contraryFacts = "The clinic letter dates the first visit to 3 March, which supports the claimant's account."
        #expect(r.isComplete(.disposition))
        #expect(SIUReportRenderer.markdown(r, generatedAt: Date()).contains("supports the claimant's account"))
        r.disposition = .returnToClaims; r.contraryFacts = nil
        #expect(r.isComplete(.disposition), "returning to claims does not need it")
        // A referral saved before the field existed decodes.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json.removeValue(forKey: "contraryFacts")
        let old = try JSONDecoder().decode(SIUReferral.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.contraryFacts == nil)
    }
}

