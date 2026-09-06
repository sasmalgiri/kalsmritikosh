//
//  EventAnswerComposerTests.swift
//  KalsmritikoshTests
//
//  P3-U2 — THE OWNER'S SCREENSHOT, FIXED: "is the patent granted?" asked of
//  the real pipeline must answer from the event record — "Yes — … granted
//  on <date>." with the milestone cited — never "Reported:" fact-spam. The
//  count shape gets the same law: counted from events, cited, honest zero.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3-U2 — existence + count answer from the event record", .serialized)
@MainActor
struct EventAnswerComposerTests {

    static let gen = NoiseFixtureGenerator()

    @Test("THE OWNER'S QUESTION end-to-end: yes, dated, cited — zero fact-spam")
    func existenceEndToEnd() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await rig.answer("is the patent granted?")
        print("P3-U2 existence: refused=\(a.refused) text=\(a.answerText ?? "nil")")
        let text = (a.answerText ?? "")
        #expect(!a.refused, "an answerable existence question must never refuse")
        #expect(text.lowercased().hasPrefix("yes"), "the answer leads with the verdict, got: \(text)")
        #expect(text.lowercased().contains("grant"), "the verdict names the event")
        #expect(!a.body.contains("Reported:"), "the fact-spam fallback is dead on this shape")
        #expect(a.citations.contains { $0.eventID != nil }, "the milestone row is the citation")
        #expect(a.body.contains("no model was consulted"), "the receipt rides the answer")
    }

    @Test("An existence question with no matching event answers an honest no-record")
    func existenceHonestNotFound() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await rig.answer("was the objection paid?")
        // "paid" names an event word; the grant letter holds no payment event.
        let text = ((a.answerText ?? "") + a.body)
        #expect(!text.contains("Reported:"), "no fact-spam on the not-found path either")
        if !a.refused {
            #expect(text.contains("No record") || text.lowercased().hasPrefix("yes") == false,
                    "either an honest no-record or a legitimate match — never spam")
        }
    }

    @Test("Unit: matching is deterministic, ordered, and abstains without an event word")
    func composerLaws() {
        let src = UUID()
        func ev(_ title: String, _ day: Int) -> Event {
            Event(kind: .other, date: Date(timeIntervalSince1970: Double(day) * 86_400),
                  title: title, summary: nil, entityIDs: [], sourceObjectID: src, confidence: .high)
        }
        let events = [ev("Hearing held", 100), ev("Hearing notice issued", 90),
                      ev("Patent granted", 200), ev("Hearing held", 100)]
        // Abstains when the question names no event word — the pipeline runs.
        #expect(EventAnswerComposer.composeExistence(question: "what is the meaning", events: events, documentsSearched: 3) == nil)
        // Count collapses same-title-same-day duplicates; honest zero counts.
        let count = EventAnswerComposer.composeCount(question: "how many hearings were there", events: events, documentsSearched: 3)
        #expect(count?.primaryText.hasPrefix("2 hearings") == true, "got \(count?.primaryText ?? "nil")")
        let zero = EventAnswerComposer.composeCount(question: "how many objections were there", events: events, documentsSearched: 3)
        #expect(zero?.isNotFound == true && zero?.primaryText.contains("No objections") == true)
        // Existence picks the newest match and cites it.
        let yes = EventAnswerComposer.composeExistence(question: "is the patent granted?", events: events, documentsSearched: 3)
        #expect(yes?.primaryText.hasPrefix("Yes — patent granted on") == true, "got \(yes?.primaryText ?? "nil")")
        // Determinism.
        let again = EventAnswerComposer.composeExistence(question: "is the patent granted?", events: events, documentsSearched: 3)
        #expect(yes == again)
    }

    // MARK: - A2.1 — list + aggregation gold

    @Test("A2: 'list all hearings' returns the complete deterministic list with an honest header")
    func listGold() {
        let src = UUID()
        let events = [
            Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_722_816_000), title: "Hearing held", entityIDs: [], sourceObjectID: src, datePrecision: .day),
            Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_723_420_800), title: "Hearing adjourned", entityIDs: [], sourceObjectID: src, datePrecision: .day),
            Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_732_752_000), title: "Patent granted", entityIDs: [], sourceObjectID: src, datePrecision: .day),
        ]
        let out = EventAnswerComposer.composeList(question: "list all hearings", events: events, documentsSearched: 3)
        #expect(out?.primaryText.hasPrefix("2 matching records:") == true, "got: \(out?.primaryText ?? "nil")")
        #expect(out?.supportingEvents.count == 2)
        #expect(out?.primaryText.contains("granted") == false, "the grant is not a hearing")
        // No vocabulary → nil (the pipeline runs, never a wrong list).
        #expect(EventAnswerComposer.composeList(question: "list all shipments", events: events, documentsSearched: 3) == nil)
    }

    @Test("A2: the total is computed with operands; currencies never mix")
    func aggregationGold() {
        func amount(_ v: String) -> GenericFact {
            GenericFact(subjectLabel: "s", field: "amount", value: v, status: .sourceAsserted,
                        confidence: 0.8, sourceBlockIDs: [UUID()],
                        producerVersion: DerivedProducerVersions.facts, rawMatch: nil, sourceCount: 1)
        }
        let out = EventAnswerComposer.composeAggregation(
            facts: [amount("₹15,000"), amount("₹7,000"), amount("$100")], documentsSearched: 5)
        let text = out?.primaryText ?? ""
        #expect(text.contains("Total: ₹22000") || text.contains("Total: ₹22,000".replacingOccurrences(of: ",", with: "")),
                "rupees sum: \(text)")
        #expect(text.contains("Total: $100"), "the dollar stays its own total: \(text)")
        #expect(!text.contains("22100"), "currencies are never mixed")
        // No amounts → nil.
        #expect(EventAnswerComposer.composeAggregation(facts: [], documentsSearched: 5) == nil)
    }

    @Test("A2.5: a comparison question yields two cited blocks + pure date arithmetic")
    func comparisonGold() {
        let src = UUID(), src2 = UUID()
        let filed = Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_553_126_400), title: "Patent filed", entityIDs: [], sourceObjectID: src, datePrecision: .day)
        let granted = Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_732_752_000), title: "Patent granted", entityIDs: [], sourceObjectID: src2, datePrecision: .day)
        let out = EventAnswerComposer.composeComparison(
            question: "how long between filing and the patent being granted",
            events: [filed, granted])
        let text = out?.primaryText ?? ""
        #expect(text.contains("Derived comparison:"), "got: \(text)")
        #expect(text.contains("2079 days") || text.contains("2078 days") || text.contains("2080 days"),
                "the arithmetic is real: \(text)")
        #expect(out?.supportingEvents.count == 2, "both records cited")
        // One vocabulary only → nil (never a fabricated comparison).
        #expect(EventAnswerComposer.composeComparison(
            question: "was the patent granted before everything", events: [granted]) == nil)
    }
}
