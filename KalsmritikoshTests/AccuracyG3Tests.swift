//
//  AccuracyG3Tests.swift
//  KalsmritikoshTests
//
//  Accuracy G3 (FAIR4 §5 item 1, 2026-11-25): a masked account number ("XXXX7316", "****7316", "ending 7316", "x7316")
//  matches the other masked forms and the end of the full number. FAIR4 solace q1's claim (dropped as "the identifier
//  7316 not in the quote") must be kept.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy G3 — masked account numbers")
struct AccuracyG3Tests {
    typealias C = VerifiedAnswerComposer

    @Test("G3: solace q1 — the ₹3,00,000 to Lata Menon (SBI XXXX7316) is kept, in the question and the second look")
    func solaceQ1() {
        let csv = """
        Date,Narration,Debit,Credit,Balance
        10-Jun-2026,NEFT/SOLACE HOSPITAL TRUST/ADVANCE PO-2026-118,,2400000.00,2400000.00
        15-Jun-2026,IMPS/LATA MENON/SBI XXXX7316/professional fees,300000.00,,2100000.00
        """
        let p = [C.Passage(objectID: UUID(), text: csv, fileName: "solace-bank-statement-vitalair.csv")]
        let quote = "15-Jun-2026,IMPS/LATA MENON/SBI XXXX7316/professional fees,300000.00,,2100000.00"
        #expect(C.whyNot(C.Claim(text: "On 15-Jun-2026 Vitalair paid 300000.00 to Lata Menon (SBI XXXX7316) as professional fees.",
                                 quote: quote, passage: 1, about: "LATA MENON"), passages: p) == nil)
        #expect(C.whyNot(C.Claim(text: "On 15-Jun-2026 Vitalair paid 300000.00 to Lata Menon (SBI XXXX7316) as professional fees, leaving a balance of 2100000.00.",
                                 quote: quote, passage: 1, about: "LATA MENON"), passages: p) == nil)
        // A different masked number is still refused.
        #expect(C.whyNot(C.Claim(text: "Vitalair paid 300000.00 to Lata Menon (SBI XXXX7317).", quote: quote, passage: 1, about: nil), passages: p)
                == "the identifier 7317 not in the quote")
    }

    @Test("G3: every masked style matches the others and the full number's last digits; a bare number does not match a longer one")
    func styles() {
        for claim in ["XXXX7316", "****7316", "x7316", "ending 7316", "•••• 7316"] {
            let id = C.identifiers(in: "paid to account \(claim) on Monday")
            #expect(id.first?.token == "7316" && id.first?.masked == true, "\(claim): \(id.map(\.token))")
            for source in ["SBI XXXX7316/fees", "a/c ****7316", "card x7316", "account ending 7316", "A/c No. 301200457316"] {
                #expect(C.containsIdentifier("7316", in: source, masked: true), "\(claim) in \(source)")
            }
        }
        #expect(!C.containsIdentifier("7316", in: "A/c No. 301200457316"), "an unmasked token needs whole-token boundaries")
        #expect(!C.containsIdentifier("7316", in: "XXXX17316x", masked: true))
        #expect(C.identifiers(in: "BW-V900 x4 units").allSatisfy { $0.token != "4" }, "a multiplier is not a masked number")
    }
}
