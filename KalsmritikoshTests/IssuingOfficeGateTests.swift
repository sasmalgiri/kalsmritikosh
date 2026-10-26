//
//  IssuingOfficeGateTests.swift
//  KalsmritikoshTests
//
//  Q-3 — "Which office announced …?" gets the office the release names, or an honest "not named".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Which-office questions get the named office or an honest not-named")
struct IssuingOfficeGateTests {

    static let q = "Which Justice Department office announced the case \"Mexican Citizen Indicted For Illegal Reentry\"?"

    static func answer(_ body: String, snippets: [String] = []) -> VerifiedAnswer {
        VerifiedAnswer(body: body, citations: snippets.map { VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: nil, snippet: $0) },
                       confidence: Confidence(0.7))
    }

    @Test("The office the passage names replaces a partner agency or a pasted paragraph")
    func fromPassage() {
        let a = Self.answer("The U.S. Department of Homeland Security, Immigration and Customs Enforcement, announced the case.",
                            snippets: ["The United States Attorney’s Office for the Middle District of Pennsylvania and ICE announced today that …"])
        let out = IssuingOfficeGate.apply(question: Self.q, a)
        #expect(!out.refused)
        #expect(out.body == "The U.S. Attorney's Office for the Middle District of Pennsylvania announced it.")
    }

    @Test("A U.S. Attorney named with a district gives the district office; a division gives the division")
    func forms() {
        #expect(IssuingOfficeGate.office(in: "Matthew D. Krueger, the United States Attorney for the Eastern District of Wisconsin, said")
                == "the U.S. Attorney's Office for the Eastern District of Wisconsin")
        #expect(IssuingOfficeGate.office(in: "announced Assistant Attorney General Lanny A. Breuer of the Criminal Division.")
                == "the Justice Department's Criminal Division")
        #expect(IssuingOfficeGate.office(in: "U.S. Attorney Kenneth A. Polite announced") == nil)
        // Another agency's division is not the Justice Department's (held-out chronology 2026-10-26).
        let fbi = "pleaded guilty today, announced Acting U.S. Attorney Channing D. Phillips and Special Agent in Charge of the FBI Washington Field Office Criminal Division Wayne A. Jacobs. Stanton pleaded guilty in the U.S. District Court for the District of Columbia."
        #expect(IssuingOfficeGate.office(in: fbi)?.contains("Criminal Division") != true)
        #expect(IssuingOfficeGate.office(in: fbi) == "the District of Columbia")
        #expect(QuestionCanonicalizer.normalize("I'm trying to determine which office prosecuted Daniel Navarro.") == "Which office prosecuted Daniel Navarro.")
    }

    @Test("The office line outside the cited snippet is found in the cited document's own text")
    func fromDocumentText() {
        let a = Self.answer("Paul Castellon pled guilty today to corruption charges [1].", snippets: ["Castellon pled guilty today."])
        let doc = "HIALEAH – Paul Castellon pled guilty today.\n\nBenjamin G. Greenberg, Acting United States Attorney for the Southern District of Florida, announced the plea."
        let out = IssuingOfficeGate.apply(question: Self.q, a, sourceTexts: [doc])
        #expect(out.body == "The U.S. Attorney's Office for the Southern District of Florida announced it.")
    }

    @Test("Nothing named → an honest refusal; an answer that names an office is kept")
    func refusalAndKeep() {
        let none = IssuingOfficeGate.apply(question: Self.q, Self.answer("U.S. Attorney Kenneth A. Polite announced that the defendant pled guilty."))
        #expect(none.refused && none.body == "The release doesn't name the office that announced it.")
        let good = Self.answer("The United States Attorney's Office for the District of Massachusetts announced the arrest [1].")
        #expect(IssuingOfficeGate.apply(question: Self.q, good).body == good.body)
        #expect(!IssuingOfficeGate.asksIssuingOffice("Who was sentenced?"))
    }
}
