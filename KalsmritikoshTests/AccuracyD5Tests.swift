//
//  AccuracyD5Tests.swift
//  KalsmritikoshTests
//
//  Accuracy D5 (FAIR5 §6 item 4, 2026-11-25): case, docket and file numbers that look like dates ("2025-17", "2024-0311",
//  "CR-2023-11-05", "Case No. 2023-11-05") are identifiers, not dates — unless written as a date (a date label, a month name,
//  a plain date in the text). FAIR5 inv104 q2: the conclusion naming "closed case 2025-17" was withheld. Generated variants
//  plus negatives: a wrong case number is rejected, and a case number never backs a claim's date.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy D5 — case numbers shaped like dates are identifiers")
struct AccuracyD5Tests {
    typealias C = VerifiedAnswerComposer

    static func why(_ claim: String, quote: String, passage: String? = nil) -> String? {
        let p = [C.Passage(objectID: UUID(), text: passage ?? ("Case file.\n" + quote + ".\nEnd."))]
        return C.whyNot(C.Claim(text: claim, quote: quote, passage: 1, about: nil), passages: p)
    }

    @Test("Date-shaped numbers after a code or a case label are not dates; real dates still are")
    func notDates() {
        for code in ["CR", "INV", "CASE", "WP", "CRL", "FIR"] {
            for sep in ["-", "/"] {
                for shape in ["2023-11-05", "2023/11/05", "05-11-2023", "05/11/23"] {
                    let token = code + sep + shape
                    #expect(C.values(in: "filed under \(token) by the clerk").dates.isEmpty, "\(token)")
                }
            }
        }
        for label in ["Case No. ", "Docket No. ", "File ", "Claim # ", "Ref: ", "Matter "] {
            #expect(C.values(in: "\(label)2023-11-05 was opened").dates.isEmpty, "\(label)")
        }
        // Still dates: labelled as a date, a plain date, a month name, a file name's ISO date.
        for text in ["Dated: 2023-11-05", "on 2023-11-05 the clerk", "Date: 05/11/2023", "filed 5 November 2023", "carpenter-2014-11-06-press-release"] {
            #expect(!C.values(in: text).dates.isEmpty, "\(text)")
        }
    }

    @Test("YYYY-NN with no month and no year range is an identifier; a year-month or a year range is not")
    func yearNumbers() {
        for t in ["2025-17", "2024-0311", "2019-44", "2026-001"] { #expect(C.isYearNumberIdentifier(t), "\(t)") }
        for t in ["2026-03", "2025-26", "2019-20", "2019-2023"] { #expect(!C.isYearNumberIdentifier(t), "\(t)") }
        #expect(C.identifiers(in: "closed case 2025-17 on file").map(\.token) == ["2025-17"])
    }

    @Test("FAIR5 inv104 q2: the conclusion naming closed case 2025-17 is shown when a sent document holds it; a wrong case number is withheld")
    func inv104() {
        let prior = C.Passage(objectID: UUID(), text: "# Closed case 2025-17 — summary\nClosed: 14 November 2025\nA payment of INR 18,000 to account 8804 was disputed and later settled by a credit note.",
                              fileName: "inv104-prior-case-2025-17-summary.md")
        let bank = C.Passage(objectID: UUID(), text: "Statement\n| 2026-03-06 | Transfer to Kestrel, a/c 8804 | INR 50,000 |", fileName: "bank.md")
        let claims = [C.VerifiedClaim(text: "On 2026-03-06 INR 50,000 went to a/c 8804.", quote: "| 2026-03-06 | Transfer to Kestrel, a/c 8804 | INR 50,000 |", passage: 2)]
        let passages = [bank, prior]
        #expect(C.conclusionWithheld("INR 50,000 went out; the INR 50,000 is not from closed case 2025-17.", claims: claims, arithmetic: [], passages: passages) == nil)
        #expect(C.conclusionWithheld("INR 50,000 went out; the INR 50,000 is not from closed case 2025-18.", claims: claims, arithmetic: [], passages: passages) != nil)
        #expect(C.conclusionWithheld("INR 50,000 went out; not from case 2024-0311.", claims: claims, arithmetic: [], passages: passages) != nil)
    }

    @Test("Claims: the same case number is kept, another rejected; a case number never backs a date")
    func claims() {
        for (id, other) in [("2025-17", "2025-18"), ("CR-2023-11-05", "CR-2023-11-06"), ("2024-0311", "2024-0312")] {
            let q = "The matter was registered as case \(id) at the registry"
            #expect(Self.why("It was registered as case \(id).", quote: q) == nil, "\(id)")
            #expect(Self.why("It was registered as case \(other).", quote: q) != nil, "\(other) vs \(id)")
        }
        #expect(Self.why("It was registered on 5 November 2023.", quote: "The matter was registered as case CR-2023-11-05 at the registry") != nil,
                "a case number is no date")
        #expect(Self.why("It was registered on 5 November 2023.", quote: "Case No. 2023-11-05 registered at the registry today") != nil)
        #expect(Self.why("It was registered on 5 November 2023.", quote: "The matter was registered on 2023-11-05 at the registry") == nil)
    }
}
