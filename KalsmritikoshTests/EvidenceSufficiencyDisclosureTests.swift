//
//  EvidenceSufficiencyDisclosureTests.swift
//  KalsmritikoshTests
//
//  U-6 (SPEC A1) — the not-found disclosure reports ARCHIVE-WIDE numbers
//  (not the candidate window) with real plurals. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-6 evidence-sufficiency disclosure")
struct EvidenceSufficiencyDisclosureTests {

    @Test func archiveTotalOverridesCandidateWindow() {
        let s = EvidenceSufficiency(covered: [], missing: [.monetaryAmount],
                                    documentsSearched: 8, archiveDocumentsSearched: 716)
        // Says 716 (the whole archive), never 8 (the retrieved window).
        #expect(s.disclosure().contains("716 documents"))
        #expect(!s.disclosure().contains(" 8 "))
    }

    @Test func realPluralsNoParenthesisedS() {
        let one = EvidenceSufficiency(covered: [], missing: [.date],
                                      documentsSearched: 1)
        #expect(one.disclosure().contains("1 document searched"))
        #expect(!one.disclosure().contains("document(s)"))

        let many = EvidenceSufficiency(covered: [], missing: [.date], documentsSearched: 42)
        #expect(many.disclosure().contains("42 documents searched"))
    }

    @Test func nilArchiveFallsBackToCandidateWindow() {
        let s = EvidenceSufficiency(covered: [], missing: [.status], documentsSearched: 5)
        #expect(s.disclosure().contains("5 documents"))
    }
}
