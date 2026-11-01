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
}
