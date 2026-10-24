//
//  OpinionAuthorBylineTests.swift
//  KalsmritikoshTests
//
//  Evidence-only round (2026-10-24): civil decisions whose byline reads "ALEXANDER, Justice." or
//  "VAN ORSDEL, Associate Justice." answered "none of the documents carries an opinion by".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Opinion bylines in every common form")
struct OpinionAuthorBylineTests {

    @Test("Justice / Judge / J. bylines", arguments: [
        ("Appeal from Harris County.\nALEXANDER, Justice.\nThis suit was brought …", "Alexander"),
        ("Before MARTIN, Chief Justice, VAN ORSDEL, Associate Justice, and BARBER, Judge.\nVAN ORSDEL, Associate Justice.\nAppellant …", "Van Orsdel"),
        ("Rehearing denied.\nYOUNG, 'Justice.\nThe appellee sued …", "Young"),
        ("Opinion\nBROWN, J.\nPetitioner seeks …", "Brown"),
        ("KEARSE, Circuit Judge:\nWe affirm.", "Kearse"),
    ])
    func bylines(_ pair: (String, String)) {
        #expect(LegalCaseDomainPack.opinionAuthor(in: pair.0) == pair.1)
    }

    @Test("Lists and concurrences are not the author")
    func notAuthors() {
        #expect(LegalCaseDomainPack.opinionAuthor(in: "Before MARTIN, Chief Justice, VAN ORSDEL, Associate Justice, and BARBER, Judge of the Court.") == nil)
        #expect(LegalCaseDomainPack.opinionAuthor(in: "The judgment is affirmed.\nSMITH, J., concurring.\nI agree.") == nil)
    }
}
