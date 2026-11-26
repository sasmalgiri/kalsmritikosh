//
//  AccuracyFixesTests.swift
//  KalsmritikoshTests
//
//  Accuracy F1–F5 (FAIR3 root cause, 2026-11-25): the app does exact work, the AI judges.
//  F1 same-document support, quote arithmetic, line-break-hyphenated numbers; F5 document identifiers as whole tokens and
//  labelled header dates. (F2–F4 tests are in the suites below in this file.)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy F1 — same-document support, quote arithmetic, broken numbers")
struct AccuracyF1Tests {
    typealias C = VerifiedAnswerComposer

    static let valenti = """
    The Association's loss totalled $122,-
    466. Before the claimed loan, seven wire transfers of $59,000 went to his mother. During the indictment period checks of $63,466 were drawn.
    """

    @Test("F1(c): a number broken at a line end with a hyphen or a soft hyphen is one number")
    func brokenNumbers() {
        #expect(C.values(in: "loss totalled $122,-466").money == [122_466])
        #expect(C.values(in: "loss totalled $122,-\n466").money == [122_466])
        #expect(C.values(in: "loss totalled $122,\u{00AD}466").money == [122_466])
        // A dash that is not a line break between digit groups stays as it was.
        #expect(C.values(in: "pages 12-466").numbers.contains(466))
        #expect(C.values(in: "a price of 500,- 300 more").numbers == [500, 300])
    }

    @Test("F1(b): a value that is the exact sum or difference of amounts in its own quote is shown as app arithmetic")
    func quoteArithmetic() {
        let passages = [C.Passage(objectID: UUID(), text: "Wires of $59,000 and checks of $63,466 were taken from the Association.")]
        let reply = #"{"status":"answered","claims":[{"text":"The $122,466 loss was $59,000 plus $63,466.","quote":"Wires of $59,000 and checks of $63,466 were taken","passage":1}]}"#
        let v = C.verify(C.parse(reply)!, passages: passages, question: "q", person: nil)
        #expect(v.dropped.isEmpty)
        #expect(v.verified.first?.support == ["app arithmetic: 59,000 + 63,466 = 122,466"])
        // Difference too.
        let diff = C.check(C.Claim(text: "Ardmore kept $50,000.", quote: "received $600,000 and paid out $550,000", passage: 1, about: nil),
                           passages: [C.Passage(objectID: UUID(), text: "Ardmore received $600,000 and paid out $550,000 on 8 September.")],
                           verified: [])
        #expect(diff.why == nil)
        #expect(diff.support == ["app arithmetic: 600,000 − 550,000 = 50,000"])
        // A number that is no sum or difference is still dropped; small counts are never made by arithmetic.
        #expect(C.whyNot(C.Claim(text: "The loss was $122,467.", quote: "Wires of $59,000 and checks of $63,466 were taken", passage: 1, about: nil),
                         passages: passages) == "the amount not in the quote")
        #expect(C.whyNot(C.Claim(text: "Three people signed.", quote: "1 director and 2 officers signed the form", passage: 1, about: nil),
                         passages: [C.Passage(objectID: UUID(), text: "1 director and 2 officers signed the form.")]) == nil,
                "a plain number word is prose, unchanged")
        #expect(C.whyNot(C.Claim(text: "3 people signed.", quote: "1 director and 2 officers signed the form", passage: 1, about: nil),
                         passages: [C.Passage(objectID: UUID(), text: "1 director and 2 officers signed the form.")]) == "the number 3 not in the quote")
    }

    @Test("F1(a): a value in another VERIFIED quote of the same document is accepted, both quotes shown; another document's is not")
    func sameDocumentSupport() {
        let id = UUID()
        let text = "Glatfelter was ordered to pay disgorgement of $340,369.77. The disgorgement is deemed satisfied by the restitution order entered on December 18, 2014 in the criminal case."
        let passages = [C.Passage(objectID: id, text: text), C.Passage(objectID: UUID(), text: "Other document: disgorgement of $999.00 was paid.")]
        let reply = #"""
        {"status":"answered","claims":[
          {"text":"Glatfelter's $340,369.77 disgorgement was deemed satisfied by the December 18, 2014 restitution order.","quote":"The disgorgement is deemed satisfied by the restitution order entered on December 18, 2014","passage":1},
          {"text":"She was ordered to pay $340,369.77 disgorgement.","quote":"ordered to pay disgorgement of $340,369.77","passage":1}]}
        """#
        let v = C.verify(C.parse(reply)!, passages: passages, question: "q", person: nil)
        #expect(v.dropped.isEmpty, "the first claim is kept in the second round")
        #expect(v.verified.count == 2)
        let kept = v.verified.first { $0.text.hasPrefix("Glatfelter") }
        #expect(kept?.support.count == 1)
        #expect(kept?.support.first?.hasPrefix("the same document also says: ") == true)
        #expect(kept?.support.first?.contains("340,369.77") == true)
        // Both quotes are shown in the answer.
        let a = C.answered(v.verified, passages: passages, dropped: 0)
        #expect(a.body.contains("the same document also says"))
        // A verified quote of ANOTHER document never backs a value.
        let cross = #"""
        {"status":"answered","claims":[
          {"text":"Glatfelter's $999.00 disgorgement was deemed satisfied.","quote":"The disgorgement is deemed satisfied by the restitution order","passage":1},
          {"text":"Disgorgement of $999.00 was paid.","quote":"disgorgement of $999.00 was paid","passage":2}]}
        """#
        let w = C.verify(C.parse(cross)!, passages: passages, question: "q", person: nil)
        #expect(w.dropped == ["the amount not in the quote"])
        // An UNVERIFIED sibling quote never backs a value.
        let unverified = #"""
        {"status":"answered","claims":[
          {"text":"Glatfelter's $340,369.77 disgorgement was deemed satisfied.","quote":"The disgorgement is deemed satisfied by the restitution order","passage":1},
          {"text":"She was ordered to pay $340,369.77.","quote":"ordered to pay a fine of $340,369.77","passage":1}]}
        """#
        #expect(C.verify(C.parse(unverified)!, passages: passages, question: "q", person: nil).verified.isEmpty)
    }

    @Test("F1: the conclusion counts the line-break-hyphenated amount of a checked quote")
    func conclusionBrokenNumber() {
        let passages = [C.Passage(objectID: UUID(), text: Self.valenti)]
        let claims = [C.VerifiedClaim(text: "The loss totalled that figure.", quote: "The Association's loss totalled $122,-\n466", passage: 1)]
        #expect(C.conclusionWithheld("The loss was $122,466.", claims: claims, arithmetic: [], passages: passages) == nil)
    }
}

@Suite("Accuracy F5 — identifiers as whole tokens, labelled header dates")
struct AccuracyF5Tests {
    typealias C = VerifiedAnswerComposer

    @Test("F5: a code in the cited document's file name or header is accepted as one token; its digits are never loose numbers")
    func ownIdentifier() {
        let instruction = C.Passage(objectID: UUID(), text: "Payment instruction\nDate of instruction: 3 September 2026\nPlease pay 600,000.00 to Ardmore Project Services Ltd.",
                                    fileName: "vantage-payment-instruction-VQ-REL-01.txt")
        #expect(C.whyNot(C.Claim(text: "Instruction VQ-REL-01 asked to pay 600,000.00 to Ardmore.", quote: "Please pay 600,000.00 to Ardmore Project Services Ltd",
                                 passage: 1, about: nil), passages: [instruction]) == nil)
        // Another code is not the document's own.
        #expect(C.whyNot(C.Claim(text: "Instruction VQ-REL-02 asked to pay 600,000.00 to Ardmore.", quote: "Please pay 600,000.00 to Ardmore Project Services Ltd",
                                 passage: 1, about: nil), passages: [instruction]) == "the identifier VQ-REL-02 not in the quote")
        // A header line holds it.
        let invoice = C.Passage(objectID: UUID(), text: "Bluewater Marine Consulting LLC\nINVOICE No. BMC-0311\nInvoice date: 3 March 2026\nTotal due 180,000.00 for the survey advisory work.")
        #expect(C.whyNot(C.Claim(text: "Invoice BMC-0311 totals 180,000.00.", quote: "Total due 180,000.00 for the survey advisory work", passage: 1, about: nil),
                         passages: [invoice]) == nil)
        #expect(C.whyNot(C.Claim(text: "Invoice FR-12 totals 180,000.00.", quote: "Total due 180,000.00 for the survey advisory work", passage: 1, about: nil),
                         passages: [invoice]) == "the identifier FR-12 not in the quote")
    }

    @Test("F5: an identifier in ANY verified quote is accepted (another document); an account number is one token")
    func identifierInVerifiedQuote() {
        let bank = C.Passage(objectID: UUID(), text: "03/09/2026 To Ardmore Project Services Ltd ref VQ-REL-01 600,000.00", fileName: "bank.txt")
        let ledger = C.Passage(objectID: UUID(), text: "The client account paid Ardmore 600,000.00 on 03/09/2026.", fileName: "ledger.txt")
        let reply = #"""
        {"status":"answered","claims":[
          {"text":"The client account paid 600,000.00 to Ardmore on 03/09/2026, ref VQ-REL-01.","quote":"The client account paid Ardmore 600,000.00 on 03/09/2026","passage":2},
          {"text":"The bank shows 600,000.00 to Ardmore.","quote":"To Ardmore Project Services Ltd ref VQ-REL-01 600,000.00","passage":1}]}
        """#
        let v = C.verify(C.parse(reply)!, passages: [bank, ledger], question: "q", person: nil)
        #expect(v.dropped.isEmpty)
        // Account numbers: "account 8804" is a token, accepted from the header.
        let mandate = C.Passage(objectID: UUID(), text: "Kestrel Traders — account 8804 mandate\nSignatories\nArjun Mehta is the director and authorised signatory.")
        #expect(C.whyNot(C.Claim(text: "Arjun Mehta is the signatory of Kestrel's account 8804.", quote: "Arjun Mehta is the director and authorised signatory",
                                 passage: 1, about: nil), passages: [mandate]) == nil)
        #expect(C.whyNot(C.Claim(text: "Arjun Mehta is the signatory of account 8805.", quote: "Arjun Mehta is the director and authorised signatory",
                                 passage: 1, about: nil), passages: [mandate]) == "the identifier 8805 not in the quote")
        #expect(C.identifiers(in: "paid ****2218 and XXXX8804, codes INV-104 and NPA-2026-014/1 on 2026-03-04").map(\.token)
                == ["INV-104", "NPA-2026-014/1", "2218", "8804"])
    }

    @Test("F5: the conclusion may name a code from a checked quote or the cited document's file name")
    func conclusionIdentifier() {
        let p = [C.Passage(objectID: UUID(), text: "Please pay 600,000.00 to Ardmore Project Services Ltd.", fileName: "vantage-payment-instruction-VQ-REL-01.txt")]
        let claims = [C.VerifiedClaim(text: "The instruction asked to pay 600,000.00.", quote: "Please pay 600,000.00 to Ardmore Project Services Ltd", passage: 1)]
        #expect(C.conclusionWithheld("Hanley signed VQ-REL-01 for 600,000.00.", claims: claims, arithmetic: [], passages: p) == nil)
        #expect(C.conclusionWithheld("Hanley signed VQ-REL-07 for 600,000.00.", claims: claims, arithmetic: [], passages: p) != nil)
    }

    @Test("F5: a labelled Date: or Sent: line among the first ten lines is the document's own date")
    func labelledHeaderDate() {
        let eml = """
        From: Leona Marsh <l.marsh@deeplinedredging.com>
        To: Katharina Voss <kvoss.bmc@mailbox-net.com>
        Cc: Graham Pell <g.pell@deeplinedredging.com>
        Subject: Survey advisory fee - BMC-0311
        Date: Fri, 13 Mar 2026 16:42:10 -0500

        We sent the survey advisory fee of $180,000 against your invoice BMC-0311 today.
        """
        let p = [C.Passage(objectID: UUID(), text: eml, fileName: "harbor-email-marsh-to-voss.eml")]
        #expect(C.whyNot(C.Claim(text: "Marsh's email of 13 Mar 2026 says the $180,000 fee was sent today.",
                                 quote: "We sent the survey advisory fee of $180,000 against your invoice BMC-0311 today", passage: 1, about: nil),
                         passages: p) == nil)
        #expect(C.whyNot(C.Claim(text: "Marsh's email of 14 Mar 2026 says the $180,000 fee was sent today.",
                                 quote: "We sent the survey advisory fee of $180,000 against your invoice BMC-0311 today", passage: 1, about: nil),
                         passages: p) == "the date not in the quote")
        // A Date: line deep in the body is not the header.
        let deep = (1...12).map { "Line \($0) of the body without a full stop" }.joined(separator: "\n") + "\nDate: 14 Mar 2026\nWe paid $180,000 today."
        #expect(C.documentDates(passage: deep, fileName: nil).dates.isEmpty)
    }
}
