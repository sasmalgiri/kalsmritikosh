//
//  TopicScoreboardTests.swift
//  KalsmritikoshTests
//
//  M4 — the topic-quality scoreboard classifier: document-shaped labels are
//  flagged; real-world subjects are not; the stats math is correct.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct TopicScoreboardTests {

    @Test("Document-shaped labels are flagged")
    func documentShapedFlagged() {
        #expect(TopicScoreboard.isDocumentShaped("RESUME_2-9309f15b"))   // hex suffix
        #expect(TopicScoreboard.isDocumentShaped("GDPR_Report_patent"))  // underscore + doc word
        #expect(TopicScoreboard.isDocumentShaped("resume.pdf"))          // extension
        #expect(TopicScoreboard.isDocumentShaped("RESUME_2"))            // all-caps + digit/underscore
    }

    @Test("Real-world subjects are NOT flagged")
    func realSubjectsClean() {
        #expect(!TopicScoreboard.isDocumentShaped("Riyaz Ahmed"))
        #expect(!TopicScoreboard.isDocumentShaped("Khurana & Khurana"))
        #expect(!TopicScoreboard.isDocumentShaped("The Patent Office"))
    }

    @Test("Scoreboard math: fractions computed from the split")
    func math() {
        let s = TopicScoreboard.from(
            identifiers: ["Riyaz Ahmed", "RESUME_2-9309f15b", "Acme Corp", "GDPR_Report_patent"],
            aiPolished: 2)
        #expect(s.total == 4)
        #expect(s.documentShaped == 2)
        #expect(s.subjectShaped == 2)
        #expect(abs(s.subjectShapedFraction - 0.5) < 0.0001)
        #expect(abs(s.polishedFraction - 0.5) < 0.0001)
    }
}
