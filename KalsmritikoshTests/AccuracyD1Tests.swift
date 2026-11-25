//
//  AccuracyD1Tests.swift
//  KalsmritikoshTests
//
//  Accuracy D1 (FAIR5 §6 item 1, 2026-11-25): references to documents and their parts are labels, not figures —
//  "Document 3", "Doc. 3", "D3", "[D3]", "passage 3", release / docket numbers ("26-088MR", "IP/13/1208", "LR-22720",
//  "No. 7321-16"), "exhibit SW/07", "page 2", "para 7", "§ 4", "Annex B", "Schedule 2", file names, and a document named by
//  its own date or year ("the 2023 release"). Property-style over generated variants plus the FAIR5 examples; the
//  negatives: a wrong amount, date or identifier beside a reference is still rejected, and a reference no document holds
//  is rejected.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy D1 — document labels and release numbers are not figures")
struct AccuracyD1Tests {
    typealias C = VerifiedAnswerComposer

    /// Five releases, each headed by its own number (as the ASIC releases of FAIR5 intl5-berndale).
    static let releases = ["23-143MR", "24-204MR", "25-135MR", "26-088MR", "26-182MR"]
    static func berndale() -> [C.Passage] {
        releases.enumerated().map { i, r in
            let body = i == 0
                ? "Two former directors have been charged with dishonesty offences, including misusing over $1 million in company funds.\nThey are next due to appear on 25 August 2023."
                : i == 2 ? "Mr Daniel Kirby was sentenced on 10 July 2025 in the Federal Court in Melbourne."
                : i == 4 ? "Mr D’Amore improperly transferred $681,496.98 in company funds. Mr Kirby was sentenced on 15 July 2025."
                : "Mr D’Amore has pleaded guilty to the illegal transfer of $681,496.98 in company funds between 2017 and 2018."
            return C.Passage(objectID: UUID(), text: "\(r) Former Berndale director\nAustralian Securities & Investments Commission — media release \(r)\n\n\(body)",
                             fileName: "berndale-asic-\(r.lowercased()).txt")
        }
    }
    static func why(_ text: String, _ quote: String, _ n: Int, _ p: [C.Passage]) -> String? {
        C.whyNot(C.Claim(text: text, quote: quote, passage: n, about: nil), passages: p)
    }

    @Test("FAIR5 berndale q1/q2: release numbers and 'the 2023 release' are kept; a wrong figure beside them is not")
    func fair5Berndale() {
        let p = Self.berndale()
        let q = "transferred $681,496.98 in company funds"
        #expect(Self.why("26-182MR gives the same figure of $681,496.98.", q, 5, p) == nil)
        #expect(Self.why("26-088MR says Mr D’Amore made the illegal transfer of $681,496.98.", "the illegal transfer of $681,496.98 in company funds", 4, p) == nil)
        #expect(Self.why("25-135MR says Mr Kirby was sentenced on 10 July 2025 in the Federal Court in Melbourne.",
                         "Mr Daniel Kirby was sentenced on 10 July 2025 in the Federal Court in Melbourne", 3, p) == nil)
        #expect(Self.why("The 2023 release gave a combined figure of over $1 million for both directors.",
                         "including misusing over $1 million in company funds", 1, p) == nil)
        // Negatives: a wrong amount, a wrong date, a release number no document has, a year the cited document never writes.
        #expect(Self.why("26-182MR gives the figure of $681,496.99.", q, 5, p) != nil)
        #expect(Self.why("25-135MR says Mr Kirby was sentenced on 11 July 2025.", "Mr Daniel Kirby was sentenced on 10 July 2025 in the Federal Court", 3, p) != nil)
        #expect(Self.why("26-999MR gives the same figure of $681,496.98.", q, 5, p) != nil)
        #expect(Self.why("The 2019 release gave a combined figure of over $1 million.", "including misusing over $1 million in company funds", 1, p) != nil)
    }

    @Test("Request labels in every form, for every sent document; out of range is not a label; values beside them still checked")
    func requestLabels() {
        let p = Self.berndale()
        let q = "transferred $681,496.98 in company funds"
        for n in 1...p.count {
            for form in ["Document \(n)", "Doc. \(n)", "D\(n)", "[D\(n)]", "passage \(n)", "Document \(n)'s account", "[Document \(n)]"] {
                #expect(Self.why("\(form) and Document 5 give $681,496.98.", q, 5, p) == nil, "\(form)")
                #expect(Self.why("\(form) gives $681,497.98.", q, 5, p) != nil, "wrong amount kept beside \(form)")
                #expect(Self.why("\(form) gives $681,496.98 on 3 May 2024.", q, 5, p) != nil, "unbacked date kept beside \(form)")
            }
        }
        #expect(Self.why("Documents 1, 2 and 4 agree on $681,496.98.", q, 5, p) == nil)
        #expect(Self.why("Document 9 gives $681,496.98.", q, 5, p) != nil, "only 5 documents were sent")
        #expect(Self.why("Document 2 says the plea covered 40 boxes.", q, 5, p) != nil)
    }

    @Test("Release, docket and file numbers of any style, from any sent document's header or file name")
    func releaseShapes() {
        for id in ["26-088MR", "IP/13/1208", "LR-22720", "No. 7321-16", "SEC/2023/456", "10-K"] {
            let header = "Release \(id)\nAgency media centre"
            let p = [C.Passage(objectID: UUID(), text: "Statement\n\nThe firm paid a penalty of €485,456,000 to the authority.", fileName: "decision.txt"),
                     C.Passage(objectID: UUID(), text: header + "\n\nEarlier text.", fileName: "other.txt")]
            let q = "The firm paid a penalty of €485,456,000 to the authority"
            #expect(Self.why("The firm paid €485,456,000, as \(id) also reports.", q, 1, p) == nil, "\(id)")
            #expect(Self.why("The firm paid €485,456,001, as \(id) also reports.", q, 1, p) != nil, "wrong amount beside \(id)")
            let none = [p[0], C.Passage(objectID: UUID(), text: "Release\nAgency media centre\n\nEarlier text.", fileName: "other.txt")]
            #expect(Self.why("The firm paid €485,456,000, as \(id) also reports.", q, 1, none) != nil, "\(id) in no document")
        }
        // A scale amount is not a code.
        #expect(C.identifiers(in: "a fine of 3-5M was proposed").isEmpty)
        // A file name of a sent document.
        let p = Self.berndale()
        #expect(Self.why("berndale-asic-26-182mr.txt gives $681,496.98.", "transferred $681,496.98 in company funds", 5, p) == nil)
        #expect(Self.why("berndale-asic-27-001mr.txt gives $681,496.98.", "transferred $681,496.98 in company funds", 5, p) != nil)
    }

    @Test("Another document's own year names that document (FAIR5 mayfield / 4x)")
    func otherDocumentYear() {
        let p = [C.Passage(objectID: UUID(), text: "SEC charges executives\nW. Emery Matthew, chief investment officer", fileName: "mayfield-2013-03-05-release.txt"),
                 C.Passage(objectID: UUID(), text: "Court enters judgment\nW. Emery Matthews was ordered to pay", fileName: "mayfield-2016-02-08-release.txt")]
        #expect(Self.why("The 2013 release spells the name W. Emery Matthew, while the 2016 release writes W. Emery Matthews.", "W. Emery Matthews was ordered to pay", 2, p) == nil)
        #expect(Self.why("The 2013 and 2016 releases spell it differently: W. Emery Matthews.", "W. Emery Matthews was ordered to pay", 2, p) == nil)
        #expect(Self.why("The March 2013 release names W. Emery Matthews.", "W. Emery Matthews was ordered to pay", 2, p) == nil)
        // Negatives: a year no document is dated, a full date that is no document's date, a year as an event.
        #expect(Self.why("The 2014 release writes W. Emery Matthews.", "W. Emery Matthews was ordered to pay", 2, p) != nil)
        #expect(Self.why("The 9 March 2013 release writes W. Emery Matthews.", "W. Emery Matthews was ordered to pay", 2, p) != nil)
        #expect(Self.why("In 2013 W. Emery Matthews was ordered to pay.", "W. Emery Matthews was ordered to pay", 2, p) != nil)
    }

    @Test("Parts of a document: written with their keyword, the document's own pages and headings; a missing part is rejected")
    func parts() {
        let text = "CONTRACT\n4. Disclosure\nThe contractor shall disclose every consultant.\nSchedule 2 — Prices\nAnnex B lists the sites.\nExhibit SW/07 was seized.\u{0C}Page two text: total 180,000.00"
        let p = [C.Passage(objectID: UUID(), text: text, fileName: "contract.txt")]
        let q = "The contractor shall disclose every consultant"
        for ref in ["clause 4", "§ 4", "Section 4", "para 4", "Schedule 2", "Annex B", "Exhibit SW/07", "page 2", "pages 1 and 2"] {
            #expect(Self.why("Under \(ref) the contractor shall disclose every consultant.", q, 1, p) == nil, "\(ref)")
        }
        for ref in ["Schedule 9", "Annex F", "page 7", "Exhibit SW/08"] {
            #expect(Self.why("Under \(ref) the contractor shall disclose every consultant.", q, 1, p) != nil, "\(ref) is not in the document")
        }
        // A count beside a reference is still a count the quote must carry.
        #expect(Self.why("Page 2 says the contractor shall disclose 40 consultants.", q, 1, p) != nil)
        #expect(Self.why("Under clause 4 the contractor shall disclose every consultant of 180,000.00.", q, 1, p) != nil)
    }

    @Test("The conclusion: labels and release numbers are not figures; a wrong amount in it is still withheld")
    func conclusion() {
        let p = Self.berndale()
        let claims = [C.VerifiedClaim(text: "26-088MR gives $681,496.98.", quote: "the illegal transfer of $681,496.98 in company funds", passage: 4),
                      C.VerifiedClaim(text: "26-182MR gives $681,496.98.", quote: "transferred $681,496.98 in company funds", passage: 5)]
        #expect(C.conclusionWithheld("$681,496.98 — Document 4 and Document 5 (26-088MR and 26-182MR) agree; the 2023 release's over $1 million is the combined allegation.",
                                     claims: claims + [C.VerifiedClaim(text: "over $1 million", quote: "including misusing over $1 million in company funds", passage: 1)],
                                     arithmetic: [], passages: p) == nil)
        #expect(C.conclusionWithheld("$681,496.99 — Documents 4 and 5 agree.", claims: claims, arithmetic: [], passages: p) != nil)
        #expect(C.conclusionWithheld("$681,496.98 — Document 7 agrees.", claims: claims, arithmetic: [], passages: p) != nil)
        // D1(b): a release number of another sent document (25-135MR heads Document 3) is the case's own.
        #expect(C.conclusionWithheld("$681,496.98, unlike 25-135MR.", claims: claims, arithmetic: [], passages: p) == nil)
        #expect(C.conclusionWithheld("$681,496.98, unlike 25-136MR.", claims: claims, arithmetic: [], passages: p) != nil)
    }
}
