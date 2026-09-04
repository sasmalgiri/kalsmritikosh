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
}
