//
//  AIConflictReviewFixesTests.swift
//  KalsmritikoshTests
//
//  Code review of c157aaa6 (2026-11-16): the AI conflict contract's same-figure guard read only the first figure of a
//  quote (a date's day shared by both sides made two different counts "the same figure"), dates were compared by the
//  first one read (pattern order, not text order), and the wrong-person check ran only when the reply named the person
//  (the removed two-sided pass fell back to the batch's subject). Scripted replies only: no model, no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI conflict contract — review fixes (figures, dates, the batch's subject)")
struct AIConflictReviewFixesTests {
    typealias F = CaseContradictionFinder

    static func reply(_ conflicts: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["complete": true, "conflicts": conflicts], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func batch(_ docs: [F.Document], subject: String? = nil) -> F.Batch {
        F.Batch(subject: subject, passages: docs.map { .init(objectID: $0.objectID, text: $0.text) })
    }

    @Test("A count is not read from a date: two counts on the same day, with no values given, are kept")
    func countsSharingADate() {
        let a = F.Document(objectID: UUID(), text: "On 3 March 2024, five victims were reported to the police.")
        let b = F.Document(objectID: UUID(), text: "On 3 March 2024, two victims were reported to the police.")
        let reply = Self.reply([["kind": "count", "description": "Two counts of victims.",
                                 "sides": [["document": 1, "quote": "On 3 March 2024, five victims were reported to the police."],
                                           ["document": 2, "quote": "On 3 March 2024, two victims were reported to the police."]]]])
        let v = AIConflictContract.verify(reply: reply, batch: Self.batch([a, b]), allDocuments: [a, b])
        #expect(v.verified.count == 1, "\(v.dropped)")
        #expect(AIConflictContract.derivedValue(kind: .count, quote: "On 3 March 2024, five victims were reported.") == "five")
        #expect(AIConflictContract.derivedValue(kind: .count, quote: "On 2024-03-03, 12 victims were reported.") == "12")
    }

    @Test("The same figure written two ways is still dropped; different amounts beside a shared number are not")
    func sameFigureReadsEveryFigure() {
        #expect(AIConflictContract.sameFigure(kind: .amountQuantity, values: ["paid $50,000 to 3 men", "paid 50,000 dollars to 4 men"]) != nil)
        #expect(AIConflictContract.sameFigure(kind: .amountQuantity, values: ["Count 3: he paid $500", "Count 3: he paid $700"]) == nil)
        #expect(AIConflictContract.sameFigure(kind: .count, values: ["On 3 March, five victims", "On 3 March, two victims"]) == nil)
        #expect(AIConflictContract.sameFigure(kind: .count, values: ["five victims", "5 victims"]) != nil)
    }

    @Test("Dates: one same date on every side is dropped; several dates are compared whole, not by the first one read")
    func datesComparedWhole() {
        #expect(AIConflictContract.sameFigure(kind: .dateTime, values: ["on 3 March 2024", "on March 3, 2024"]) != nil)
        // The ISO date is read first (pattern order) though it is second in the text; the sides still differ.
        #expect(AIConflictContract.sameFigure(kind: .dateTime, values: ["filed on June 9, 2024 after the 2024-05-01 meeting",
                                                                        "filed on 2024-05-01"]) == nil)
        #expect(AIConflictContract.sameFigure(kind: .dateTime, values: ["on 3 March 2024", "on 5 March 2024"]) == nil)
    }

    @Test("No \"about\" in the reply: the sides are checked against the batch's person, and a side about another Kelly is dropped")
    func batchSubjectFallback() {
        let a = F.Document(objectID: UUID(), text: "Brian M. Kelly, 50, of Boca Raton, received $120,000 from the scheme.")
        let other = F.Document(objectID: UUID(), text: "Michael Kelly, 44, of Miami, received $95,000 from homeowners.")
        let same = F.Document(objectID: UUID(), text: "Kelly received $95,000 from homeowners, according to the plea agreement.")
        func conflict(_ quoteB: String) -> String {
            Self.reply([["kind": "amount_quantity", "description": "Two amounts.",
                         "sides": [["document": 1, "quote": "received $120,000 from the scheme", "value": "$120,000"],
                                   ["document": 2, "quote": quoteB, "value": "$95,000"]]]])
        }
        let wrong = AIConflictContract.verify(reply: conflict("Michael Kelly, 44, of Miami, received $95,000 from homeowners"),
                                              batch: Self.batch([a, other], subject: "Brian M. Kelly"), allDocuments: [a, other])
        #expect(wrong.verified.isEmpty, "\(wrong.verified.map(\.description))")
        #expect(wrong.dropped.contains { $0.contains("Brian M. Kelly") && ($0.hasPrefix("a passage does not name") || $0.hasPrefix("a sentence is about someone else")) },
                "\(wrong.dropped)")
        let right = AIConflictContract.verify(reply: conflict("Kelly received $95,000 from homeowners"),
                                              batch: Self.batch([a, same], subject: "Brian M. Kelly"), allDocuments: [a, same])
        #expect(right.verified.count == 1, "\(right.dropped)")
    }
}
