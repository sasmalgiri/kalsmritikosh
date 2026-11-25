//
//  AccuracyUniversalityTests.swift
//  KalsmritikoshTests
//
//  Accuracy universality (owner 2026-11-25: "it should work for any case"). Property-style checks of the accuracy fixes
//  F1–F5 and G1–G5 over generated variants — several currencies × number styles × scale words, both date conventions and
//  other date forms, masked vs full account numbers, IBANs and docket numbers, name variants — and the negative side of
//  every guarantee: a wrong amount, a different date, a different identifier or surname is still rejected. Nothing here
//  names a fixture's party or value.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy — universality over generated variants")
struct AccuracyUniversalityTests {
    typealias C = VerifiedAnswerComposer

    /// The verifier's reason for one claim quoting `quote` from a passage holding it (nil = kept).
    static func why(_ claim: String, quote: String, passage: String? = nil, about: String? = nil) -> String? {
        let p = [C.Passage(objectID: UUID(), text: passage ?? ("Statement of account.\nThe record says: " + quote + ".\nEnd of page."))]
        return C.whyNot(C.Claim(text: claim, quote: quote, passage: 1, about: about), passages: p)
    }

    // MARK: Number styles × currencies

    /// A whole amount written in one style.
    static func styled(_ v: Int, _ style: String) -> String {
        let digits = String(v)
        func group(_ s: String, _ sep: String, indian: Bool = false) -> String {
            var out: [String] = []
            var rest = Substring(s)
            out.insert(String(rest.suffix(3)), at: 0); rest = rest.dropLast(min(3, rest.count))
            while !rest.isEmpty {
                let n = indian ? 2 : 3
                out.insert(String(rest.suffix(n)), at: 0); rest = rest.dropLast(min(n, rest.count))
            }
            return out.joined(separator: sep)
        }
        switch style {
        case "western": return group(digits, ",")
        case "westernCents": return group(digits, ",") + ".00"
        case "indian": return group(digits, ",", indian: true)
        case "european": return group(digits, ".") + ",00"
        case "swiss": return group(digits, "'")
        case "nbsp": return group(digits, "\u{00A0}")
        default: return digits
        }
    }

    static let currencies = ["$", "€", "£", "₹", "INR ", "EUR ", "CHF ", "Rs.", "AED ", "¥", ""]
    static let styles = ["western", "westernCents", "indian", "european", "swiss", "nbsp", "plain"]

    @Test("Any currency × any number style: the same amount is kept; a different amount (a subset of digit groups, or the groups reordered) is rejected")
    func amountsAnyStyle() {
        let pairs = [(350_000, 300_000), (1_234_000, 1_000_234), (12_500_000, 12_000_500), (45_600, 45_000)]
        for cur in Self.currencies {
            for style in Self.styles {
                for (v, w) in pairs {
                    let quote = "a transfer of \(cur)\(Self.styled(v, style)) was made to the supplier"
                    #expect(Self.why("The supplier received \(cur)\(Self.styled(v, style)).", quote: quote) == nil, "\(cur) \(style) \(v)")
                    #expect(Self.why("The supplier received \(cur)\(Self.styled(w, style)).", quote: quote) != nil, "WRONG amount kept: \(cur) \(style) \(w) vs \(v)")
                    // The claim may write the amount in another style than the document.
                    #expect(Self.why("The supplier received \(cur)\(Self.styled(v, "western")).", quote: quote) == nil, "\(cur) \(style)→western \(v)")
                    #expect(Self.why("The supplier received \(cur)\(Self.styled(w, "western")).", quote: quote) != nil, "WRONG cross-style: \(cur) \(style) \(w)")
                }
            }
        }
    }

    @Test("Scale words in any currency: lakh, crore, million, bn, m, k — the same value is kept, another scale is rejected")
    func scaleWords() {
        let same: [(String, String)] = [
            ("₹2 crore", "₹2,00,00,000"), ("₹2 crore", "₹2 crore"), ("Rs. 5 lakh", "Rs. 5,00,000"), ("INR 1.5 lakh", "INR 1,50,000"),
            ("£3bn", "£3 billion"), ("€5m", "€5 million"), ("EUR 2.5 million", "EUR 2,500,000"), ("$40k", "$40,000"), ("AED 3 mn", "AED 3,000,000"),
        ]
        for (claim, quote) in same {
            #expect(Self.why("The loss was \(claim).", quote: "the loss was \(quote) in total") == nil, "\(claim) vs \(quote)")
        }
        let different: [(String, String)] = [
            ("₹2 crore", "₹2 lakh"), ("₹2 lakh", "₹2 crore"), ("£3bn", "£5bn"), ("€5m", "€3m"), ("EUR 5M", "EUR 3M"), ("$40k", "$45k"),
            ("¥5M", "¥3M"), ("₹2 crore", "₹2,00,000"), ("€5m", "€5,000"),
        ]
        for (claim, quote) in different {
            #expect(Self.why("The loss was \(claim).", quote: "the loss was \(quote) in total") != nil, "WRONG scale kept: \(claim) vs \(quote)")
        }
    }

    @Test("Digits of any script are the same digits; a different number is still rejected")
    func scripts() {
        #expect(Self.why("The invoice was for 350 units.", quote: "invoice for \u{0663}\u{0665}\u{0660} units") == nil)
        #expect(Self.why("The invoice was for 360 units.", quote: "invoice for \u{0663}\u{0665}\u{0660} units") != nil)
        #expect(Self.why("The invoice was for 4,500 units.", quote: "invoice for \u{096A},\u{096B}\u{0966}\u{0966} units") == nil)
        #expect(Self.why("The invoice was for 4,600 units.", quote: "invoice for \u{096A},\u{096B}\u{0966}\u{0966} units") != nil)
        #expect(CaseAgent.amount("₹\u{0663},\u{0660}\u{0660},\u{0660}\u{0660}\u{0660}")?.value == 300_000)
    }

    // MARK: Dates

    @Test("Dates: day-first and month-first numeric, ISO, yyyy/mm/dd, written months, 2-digit years — same day kept, another day rejected")
    func dates() {
        let forms = ["04/03/2026", "4.3.2026", "2026-03-04", "2026/03/04", "4 March 2026", "March 4, 2026", "4th of March, 2026", "04 Mar 26", "Mar 4 2026"]
        for f in forms {
            #expect(Self.why("The payment was made on 4 March 2026.", quote: "payment made on \(f) by wire") == nil, "4 March vs \(f)")
            #expect(Self.why("The payment was made on 9 March 2026.", quote: "payment made on \(f) by wire") != nil, "WRONG date kept: 9 March vs \(f)")
            #expect(Self.why("The payment was made on 4 March 2025.", quote: "payment made on \(f) by wire") != nil, "WRONG year kept: 2025 vs \(f)")
        }
        // Month-first: "03/04/2026" read either way (the verifier never picks one reading).
        #expect(Self.why("Paid on April 3, 2026.", quote: "paid 03/04/2026") == nil)
        #expect(Self.why("Paid on April 5, 2026.", quote: "paid 03/04/2026") != nil)
        // Ranges: each end of "3–5 March 2026" is in the quote; a day outside it is not.
        #expect(Self.why("The hearing began on 3 March 2026.", quote: "hearings held 3–5 March 2026 in Court 4") == nil)
        #expect(Self.why("The hearing ended on 5 March 2026.", quote: "hearings held March 3-5, 2026 in Court 4") == nil)
        #expect(Self.why("The hearing began on 6 March 2026.", quote: "hearings held 3–5 March 2026 in Court 4") != nil)
        // Quarters and halves: the digit of "Q3" counts.
        #expect(Self.why("Revenue fell in Q3 2025.", quote: "revenue fell in Q3 2025 against plan") == nil)
        #expect(Self.why("Revenue fell in Q4 2025.", quote: "revenue fell in Q3 2025 against plan") != nil)
        #expect(Self.why("Revenue fell in the third quarter of 2025.", quote: "revenue fell in Q3 2025 against plan") == nil)
        #expect(Self.why("Revenue fell in Q3 2025.", quote: "revenue fell in the third quarter of 2025 against plan") == nil)
        // Mid-month is a month.
        #expect(Self.why("The audit started in mid-March 2026.", quote: "the audit started mid-March 2026") == nil)
        #expect(Self.why("The audit started in mid-April 2026.", quote: "the audit started mid-March 2026") != nil)
    }

    @Test("G2 day/month order from any non-US or US signal; unknown keeps both readings")
    func dateOrder() {
        for t in ["Amount CHF 1'200.00 on 03/04/2026", "AED 5,000 paid 03/04/2026", "ZAR 900 on 03/04/2026", "Rs. 500 on 03/04/2026", "IFSC SBIN0001234 03/04/2026"] {
            #expect(DateOrder.dayFirst(t) == true, "\(t)")
        }
        #expect(DateOrder.dayFirst("USD 500 on 03/04/2026") == false)
        #expect(DateOrder.dayFirst("paid 03/04/2026") == nil)
        #expect(DateOrder.dayFirst("paid 03/04/2026 and 25/04/2026") == true)
        #expect(DateOrder.dayFirst("paid 03/04/2026 and 04/25/2026") == false)
    }

    // MARK: Identifiers

    @Test("Masked and full account numbers in any mask style; IBAN and docket numbers as whole tokens; a different one is rejected")
    func identifiers() {
        let masks = ["XXXX7316", "****7316", "XXXX-XXXX-7316", "xxxx xxxx 7316", "…7316", "ending 7316", "ending in 7316", "a/c no. 004512347316", "#### 7316"]
        for q in masks {
            for c in ["XXXX7316", "****7316", "ending 7316"] {
                #expect(Self.why("Paid from account \(c).", quote: "debit from account \(q) on file") == nil, "\(c) vs \(q)")
            }
            #expect(Self.why("Paid from account ending 7317.", quote: "debit from account \(q) on file") != nil, "WRONG account kept vs \(q)")
            #expect(Self.why("Paid from account XXXX7317.", quote: "debit from account \(q) on file") != nil, "WRONG masked account kept vs \(q)")
        }
        // IBAN: spaced or not, the same IBAN; one digit different is another account.
        #expect(Self.why("Paid to IBAN GB29 NWBK 6016 1331 9268 19.", quote: "beneficiary GB29NWBK60161331926819 credited") == nil)
        #expect(Self.why("Paid to IBAN GB29 NWBK 6016 1331 9268 18.", quote: "beneficiary GB29NWBK60161331926819 credited") != nil)
        // Docket and case numbers.
        for (claim, quote, ok) in [("Case No. 1:23-cv-04567", "in Case No. 1:23-cv-04567 the court", true),
                                   ("Case No. 1:23-cv-04568", "in Case No. 1:23-cv-04567 the court", false),
                                   ("Docket No. 22-1234", "Docket No. 22-1234, filed", true),
                                   ("Docket No. 1234-22", "Docket No. 22-1234, filed", false),
                                   ("claim CR-2024-0099", "under claim CR-2024-0099 the insurer", true),
                                   ("claim CR-2024-0098", "under claim CR-2024-0099 the insurer", false)] {
            let r = Self.why("The filing was under \(claim).", quote: quote)
            #expect((r == nil) == ok, "\(claim) vs \(quote): \(r ?? "kept")")
        }
    }

    @Test("A digit glued to letters is a name only when no currency stands before it (any currency)")
    func nameTokensAndCurrencies() {
        let passage = "The board fined the firm ¥3M. An earlier draft proposed ¥5M and EUR 5M. 4X Solutions and 3M Company replied."
        #expect(Self.why("The firm was fined ¥5M.", quote: "fined the firm ¥3M", passage: passage) != nil)
        #expect(Self.why("The firm was fined EUR 5M.", quote: "fined the firm ¥3M", passage: passage) != nil)
        #expect(Self.why("4X Solutions replied.", quote: "4X Solutions and 3M Company replied", passage: passage) == nil)
    }

    // MARK: Names

    @Test("About: honorifics and company suffixes in any style; a different surname or a transliteration variant is never matched")
    func names() {
        let passage = "Statement of Rajesh Iyer, director of Ardmore Project Services, and of Ms. Priya Nair (Kumari)."
        for about in ["Rajesh Iyer", "Mr Rajesh Iyer", "Shri Rajesh Iyer", "Dr. Rajesh Iyer", "IYER, Rajesh", "R. Iyer",
                      "Ardmore Project Services Pvt Ltd", "Ardmore Project Services Limited", "M/s Ardmore Project Services", "Smt. Priya Nair"] {
            #expect(Self.why("He signed.", quote: "Statement of Rajesh Iyer, director of Ardmore Project Services", passage: passage, about: about) == nil, "\(about)")
        }
        for about in ["Rajesh Ayyar", "Suresh Iyer", "Rajesh Menon", "Ardmore Holdings Ltd", "Priya Menon"] {
            #expect(Self.why("He signed.", quote: "Statement of Rajesh Iyer, director of Ardmore Project Services", passage: passage, about: about) != nil, "WRONG name kept: \(about)")
        }
    }

    @Test("G1 parties: suffixes, honorifics, dots, diacritics join one party; a near spelling (Iyer/Ayyar) stays two until the AI says same")
    func parties() {
        let d = UUID(), e = UUID()
        func rec(_ amount: String, _ from: String, _ to: String, _ date: String, _ doc: UUID) -> CaseAIRecord {
            CaseAIRecord(kind: .fact, text: "\(from) → \(to): \(amount) (payment)", entityType: CaseAIRecord.moneyType, role: "payment",
                         dateText: date, from: from, to: to, relation: amount, quote: amount, document: doc, origin: "picture")
        }
        let flows = CaseAIUnderstanding.partyFlows([
            rec("INR 5,00,000", "Mr. Rajesh Iyer", "Ardmore Project Services Pvt. Ltd.", "2026-03-04", d),
            rec("INR 5,00,000", "RAJESH IYER", "M/s Ardmore Project Services Private Limited", "04/03/2026", e),
            rec("INR 2,00,000", "Rajesh Ayyar", "Müller Trading GmbH", "2026-03-09", d),
            rec("INR 1,00,000", "Muller Trading", "Ardmore Project Services LLP", "2026-03-10", d),
        ])
        let ardmore = flows.filter { $0.names.contains { $0.contains("Ardmore") } }
        #expect(ardmore.count == 1, "\(flows.map(\.names))")
        #expect(ardmore.first?.incoming.count == 2, "the 5,00,000 recorded twice counts once; 1,00,000 from Muller")
        #expect(flows.filter { $0.names.contains { $0.contains("Iyer") || $0.contains("IYER") } }.count == 1)
        #expect(!flows.contains { f in f.names.contains { $0.contains("Iyer") } && f.names.contains { $0.contains("Ayyar") } },
                "Iyer and Ayyar are not merged by the app")
        #expect(flows.filter { $0.names.contains { $0.contains("ller Trading") } }.count == 1, "Müller = Muller")
    }

    // MARK: Guarantees stay strict

    @Test("Never loosened: verbatim quote, numbers in the quote, never a different value")
    func negatives() {
        // Verbatim.
        #expect(Self.why("He paid INR 50,000.", quote: "he paid INR 50,000 in cash", passage: "Note: he paid INR 50,000 by cheque.") != nil)
        // A number not in the quote.
        #expect(Self.why("He paid INR 50,000 on 3 March 2026 for 12 items.", quote: "he paid INR 50,000 on 3 March 2026") != nil)
        // A different amount in a style that reads as the same digit groups.
        #expect(Self.why("He paid ₹3,00,000.", quote: "he paid ₹3,50,000 to the vendor") != nil)
        #expect(Self.why("He paid €1.234,56.", quote: "he paid €1.999,56 to the vendor") != nil)
        #expect(Self.why("He paid CHF 1'234'000.", quote: "he paid CHF 1'000'234 to the vendor") != nil)
        #expect(Self.why("He paid Rs.5,00,000.", quote: "he paid Rs.2,00,000 to the vendor") != nil)
        // An ordinal or a code digit.
        #expect(Self.why("It was the 3rd instalment.", quote: "it was the 2nd instalment of the loan") != nil)
        #expect(Self.why("The aircraft was an A321.", quote: "the aircraft, an A320, landed") != nil)
        // A code the cited document writes elsewhere (a role or call sign named across it) may be named; one it never
        // writes may not.
        let report = "LC1 cleared the aircraft to cross.\nThe controller was certified and current on all positions."
        #expect(Self.why("LC1 was certified and current.", quote: "The controller was certified and current on all positions", passage: report) == nil)
        #expect(Self.why("LC3 was certified and current.", quote: "The controller was certified and current on all positions", passage: report) != nil)
        #expect(Self.why("It was the second instalment.", quote: "it was the 2nd instalment of the loan") == nil)
        #expect(Self.why("It was the 2nd instalment.", quote: "it was the second instalment of the loan") == nil)
        // G5 changes no verification: a rounded figure is never accepted as an exact one.
        #expect(Self.why("The speed was 167 knots.", quote: "the speed was about 170 knots at the gate") != nil)
        #expect(Self.why("The loss was $1,985,754.", quote: "a loss of approximately $2 million") != nil)
    }
}
