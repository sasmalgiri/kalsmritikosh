//
//  ReaderFailureReasonTests.swift
//  KalsmritikoshTests
//
//  Smoke 2026-11-03 (real case, Opus 5 readers): the case drafts made 0 drafting calls and "1 failed",
//  the role reader verified 0, the contradiction reader dropped 6 pairs — with no reason recorded
//  anywhere. Root cause of the failures: current Claude models think before answering and the thinking
//  counts against max_tokens, so a 1,500-token draft call spent all 1,500 on thinking and returned no
//  text. These tests pin: the thinking allowance on top of the reply budget; a cut-off reply named as
//  such; role readings and dropped AI conflicts carrying their reasons; a date governed by a
//  scheduled future verb never dated onto another step; the bench footer naming its cloud readers.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Reader failures recorded with their reasons")
struct ReaderFailureReasonTests {

    // MARK: - The request and the reply

    @Test("A Claude request gives the reply its own budget on top of a thinking allowance")
    func thinkingAllowance() throws {
        let r = try OnlineRequestBuilder.build(kind: .anthropic, model: "m", apiKey: "k", system: nil, prompt: "p", maxTokens: 1_500)
        let body = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 1_500 + OnlineRequestBuilder.anthropicThinkingAllowance)
        #expect(OnlineRequestBuilder.anthropicMaxTokens(16) == 1_024 + OnlineRequestBuilder.anthropicThinkingAllowance)
        #expect(OnlineRequestBuilder.anthropicMaxTokens(100_000) == 16_000 + OnlineRequestBuilder.anthropicThinkingAllowance)
        #expect(CaseDraftBuilder.readerReplyTokens >= 3_000, "events and gaps for six passages run past 2,000 tokens")
    }

    @Test("A reply that hit the output limit with no text is reported as cut off, with the thinking spent")
    func cutOffReply() {
        let body = #"{"content":[{"type":"thinking","thinking":""}],"stop_reason":"max_tokens","usage":{"output_tokens":1500,"output_tokens_details":{"thinking_tokens":1500}}}"#
        #expect(throws: OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking")) {
            try OnlineRequestBuilder.parse(kind: .anthropic, response: OutboundHTTPResponse(status: 200, body: Data(body.utf8)))
        }
        let reason = VerifiedRoleReader.reason(OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking"))
        #expect(reason.contains("cut off at the output limit") && reason.contains("1500 of them thinking"))
        #expect(VerifiedRoleReader.reason(VerifiedAnswerComposer.NotSent("declined")) == "not sent: declined")
        // A truncated reply that does carry text is still returned (the verifier then reads what it can).
        let partial = #"{"content":[{"type":"text","text":"{\"roles\": []}"}],"stop_reason":"max_tokens"}"#
        #expect((try? OnlineRequestBuilder.parse(kind: .anthropic, response: OutboundHTTPResponse(status: 200, body: Data(partial.utf8)))) == #"{"roles": []}"#)
    }

    // MARK: - Role reading

    struct Boom: Error, LocalizedError { var errorDescription: String? { "The provider had an error (HTTP 529)." } }

    @Test("The role reader reports its calls, each failure in the provider's words and why each reading was dropped")
    func roleReport() async {
        let doc = UUID()
        let passages = [VerifiedRoleReader.Passage(objectID: doc, text: "Following a jury trial before U.S. District Judge John Michael Vazquez, Harold Mignott, 60, of Voorhees, was convicted.")]
        let clearance = CloudSourceClearance(clearedObjectIDs: [doc], deniedCount: 0, checkedAt: Date(), purpose: "test")
        let reply = """
            {"roles": [
              {"person": "John Michael Vazquez", "role": "judge", "quote": "before U.S. District Judge John Michael Vazquez", "passage": 1},
              {"person": "Harold Mignott", "role": "judge", "quote": "Harold Mignott, 60, of Voorhees, was convicted", "passage": 1},
              {"person": "Harold Mignott", "role": "defendant", "quote": "Harold Mignott pleaded guilty", "passage": 1},
              {"person": "Someone Else", "role": "witness", "quote": "Someone Else testified", "passage": 1}
            ]}
            """
        let report = await VerifiedRoleReader { _, _ in reply }
            .readReporting(people: ["John Michael Vazquez", "Harold Mignott"], passages: passages, clearance: clearance)
        #expect(report.calls == 1 && report.failures.isEmpty)
        #expect(report.readings.map(\.person) == ["John Michael Vazquez"])
        #expect(report.dropped.contains { $0.contains("Harold Mignott as judge") && $0.contains("does not state the role") }, "\(report.dropped)")
        #expect(report.dropped.contains { $0.contains("Harold Mignott as defendant") && $0.contains("quote not in its passage") }, "\(report.dropped)")
        #expect(report.dropped.contains { $0.contains("Someone Else") && $0.contains("not one of the people") }, "\(report.dropped)")

        let failed = await VerifiedRoleReader { _, _ in throw Boom() }
            .readReporting(people: ["John Michael Vazquez"], passages: passages, clearance: clearance)
        #expect(failed.calls == 1 && failed.readings.isEmpty)
        #expect(failed.failures == ["role call: The provider had an error (HTTP 529)."])
        // The plain read still returns only the verified readings.
        #expect(await VerifiedRoleReader { _, _ in reply }.read(people: ["John Michael Vazquez"], passages: passages, clearance: clearance).count == 1)
    }

    // MARK: - AI conflict drops (owner request 2026-11-16: ported from the removed two-sided pass to AIConflictContract)

    static func reply(_ conflicts: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["complete": true, "conflicts": conflicts], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func conflict(_ about: String, _ a: (Int, String, String), _ b: (Int, String, String)) -> [String: Any] {
        ["kind": "amount_quantity", "about": about, "description": "Two amounts.",
         "sides": [["document": a.0, "quote": a.1, "value": a.2], ["document": b.0, "quote": b.1, "value": b.2]]]
    }

    @Test("Every dropped AI conflict carries its reason and what it proposed")
    func contradictionDropReasons() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Brian M. Kelly, 50, of Boca Raton, received $120,000 from the scheme.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Kelly received $95,000 from homeowners, according to the plea agreement.")
        let batch = CaseContradictionFinder.Batch(subject: "Brian M. Kelly", passages: [a, b].map { .init(objectID: $0.objectID, text: $0.text) })
        let reply = Self.reply([
            Self.conflict("Brian M. Kelly", (1, "received $125,000 from the scheme", "$125,000"), (2, "Kelly received $95,000 from homeowners", "$95,000")),
            Self.conflict("Brian M. Kelly", (1, "received $120,000 from the scheme", "$120,000"), (3, "Kelly received $95,000 from homeowners", "$95,000")),
            Self.conflict("Brian M. Kelly", (1, "received $120,000 from the scheme", "$120,000"), (2, "Kelly received $95,000 from homeowners", "$95,000")),
        ])
        let v = AIConflictContract.verify(reply: reply, batch: batch, allDocuments: [a, b])
        #expect(v.verified.count == 1, "\(v.dropped)")
        #expect(v.dropped.count == 2)
        #expect(v.dropped[0].hasPrefix("quote not found word for word in document 1 — about Brian M. Kelly (amount_quantity) Two amounts.: [document 1] “received $125,000 from the scheme” ($125,000) / [document 2]"), "\(v.dropped)")
        #expect(v.dropped[1].hasPrefix("cites a document that was not sent") && v.dropped[1].contains("[document 3]"), "\(v.dropped)")
    }

    @Test("Ranges sharing an endpoint still differ; a statutory maximum is explained, not a contradiction")
    func rangesAndMaximums() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Godfrey induced homeowners to pay HOPE up-front fees of $400 to $2,000 for its services.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Godfrey induced homeowners to pay HOPE up-front fees of $400-$900 for its services.")
        let c = CaseContradictionFinder.Document(objectID: UUID(), text: "The charge of conspiracy carries a maximum penalty of five years in prison.")
        let d = CaseContradictionFinder.Document(objectID: UUID(), text: "Each count of wire fraud carries a maximum penalty of 20 years in prison.")
        let batch = CaseContradictionFinder.Batch(subject: nil, passages: [a, b, c, d].map { .init(objectID: $0.objectID, text: $0.text) })
        let reply = Self.reply([
            Self.conflict("HOPE up-front fees", (1, "up-front fees of $400 to $2,000", "$400 to $2,000"), (2, "up-front fees of $400-$900", "$400-$900")),
            Self.conflict("maximum penalty in prison", (3, "carries a maximum penalty of five years in prison", "five years"),
                          (4, "carries a maximum penalty of 20 years in prison", "20 years")),
            Self.conflict("HOPE up-front fees", (1, "up-front fees of $400 to $2,000", "$400"), (2, "up-front fees of $400-$900", "$400")),
        ])
        let v = AIConflictContract.verify(reply: reply, batch: batch, allDocuments: [a, b, c, d])
        #expect(v.verified.count == 1 && v.verified.first?.sides.first?.value == "$400 to $2,000", "\(v.dropped)")
        #expect(v.dropped.contains { $0.hasPrefix("explained: a maximum penalty") }, "\(v.dropped)")
        #expect(v.dropped.contains { $0.hasPrefix("the values do not differ") }, "\(v.dropped)")
    }

    @Test("A scheduled date, and the send dates of two messages, explain an AI date conflict (the rules' date reasons)")
    func scheduledAndSendDatesExplained() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: Self.release)
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: Self.later)
        let batch = CaseContradictionFinder.Batch(subject: nil, passages: [a, b].map { .init(objectID: $0.objectID, text: $0.text) })
        let scheduled = Self.reply([["kind": "date_time", "description": "Two plea dates.",
                                     "sides": [["document": 1, "quote": "have pleaded guilty and will be sentenced on Feb. 25, 2014", "value": "Feb. 25, 2014"],
                                               ["document": 2, "quote": "Kelly pleaded guilty on May 2, 2013, to one count of conspiracy", "value": "May 2, 2013"]]]])
        let v = AIConflictContract.verify(reply: scheduled, batch: batch, allDocuments: [a, b])
        #expect(v.verified.isEmpty && v.dropped.first?.hasPrefix("explained: a scheduled date") == true, "\(v.dropped)")
        let m1 = CaseContradictionFinder.Document(objectID: UUID(), text: "Date: Fri, 9 Nov 2001 10:00:00 -0800 (PST)\nThe invoice was approved.")
        let m2 = CaseContradictionFinder.Document(objectID: UUID(), text: "Date: Mon, 12 Nov 2001 09:00:00 -0800 (PST)\nThe invoice was approved.")
        let mails = CaseContradictionFinder.Batch(subject: nil, passages: [m1, m2].map { .init(objectID: $0.objectID, text: $0.text) })
        let send = Self.reply([["kind": "date_time", "description": "Two dates.",
                                "sides": [["document": 1, "quote": "Date: Fri, 9 Nov 2001 10:00:00"], ["document": 2, "quote": "Date: Mon, 12 Nov 2001 09:00:00"]]]])
        let w = AIConflictContract.verify(reply: send, batch: mails, allDocuments: [m1, m2])
        #expect(w.verified.isEmpty && w.dropped.first?.hasPrefix("explained: the send dates of two different messages") == true, "\(w.dropped)")
    }

    @Test("Different victims, a different count and the same length of a sentence are explained or the same; one statement of one document is not two")
    func differentVictimsAndSameValueGuards() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Paul Grant defrauded four victims in Ohio.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Paul Grant was charged with 22 counts.")
        let batch = CaseContradictionFinder.Batch(subject: nil, passages: [a, b].map { .init(objectID: $0.objectID, text: $0.text) })
        let counts = Self.reply([["kind": "count", "about": "Paul Grant", "description": "Two counts.",
                                  "sides": [["document": 1, "quote": "Paul Grant defrauded four victims", "value": "four victims"],
                                            ["document": 2, "quote": "Paul Grant was charged with 22 counts", "value": "22 counts"]]]])
        let v = AIConflictContract.verify(reply: counts, batch: batch, allDocuments: [a, b])
        #expect(v.verified.isEmpty && v.dropped.first?.hasPrefix("explained: different counts") == true, "\(v.dropped)")
        let t1 = CaseContradictionFinder.Document(objectID: UUID(), text: "Vernell Burris was sentenced to a year and a day in prison.")
        let t2 = CaseContradictionFinder.Document(objectID: UUID(), text: "Vernell Burris was sentenced to 12 months and 1 day in prison.")
        let terms = CaseContradictionFinder.Batch(subject: nil, passages: [t1, t2].map { .init(objectID: $0.objectID, text: $0.text) })
        let same = Self.reply([["kind": "other", "label": "sentence length", "description": "Two lengths.",
                                "sides": [["document": 1, "quote": "was sentenced to a year and a day in prison", "value": "a year and a day"],
                                          ["document": 2, "quote": "was sentenced to 12 months and 1 day in prison", "value": "12 months and 1 day"]]]])
        let w = AIConflictContract.verify(reply: same, batch: terms, allDocuments: [t1, t2])
        #expect(w.verified.isEmpty && w.dropped.first?.hasPrefix("the values do not differ") == true, "\(w.dropped)")
        let one = CaseContradictionFinder.Document(objectID: UUID(), text: "Ravi Kumar signed the order in Pune on 4 March 2026 and left.")
        let single = CaseContradictionFinder.Batch(subject: nil, passages: [.init(objectID: one.objectID, text: one.text)])
        let self_ = Self.reply([["kind": "internal_inconsistency", "description": "One sentence.",
                                 "sides": [["document": 1, "quote": "Ravi Kumar signed the order in Pune"], ["document": 1, "quote": "on 4 March 2026 and left"]]]])
        let x = AIConflictContract.verify(reply: self_, batch: single, allDocuments: [one])
        #expect(x.verified.isEmpty && x.dropped.first?.hasPrefix("one statement of one document") == true, "\(x.dropped)")
    }

    // MARK: - The step-date rule

    static let release = """
        FOR IMMEDIATE RELEASE
        Thursday, February 20, 2014

        The remaining two defendants in the case, Vernell Burris Jr. and Brian Kelly, have pleaded guilty and will be sentenced on Feb. 25, 2014.
        """
    static let later = """
        FOR IMMEDIATE RELEASE
        Thursday, April 24, 2014

        Brian Kelly, 50, of Boca Raton, Fla., was sentenced today. Kelly pleaded guilty on May 2, 2013, to one count of conspiracy.
        """

    @Test("A date governed by a scheduled future verb is not the plea's date — no false date contradiction")
    func scheduledDateIsNotThePleaDate() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: Self.release)
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: Self.later)
        let found = CaseContradictionFinder.ruleFindings([a, b])
        #expect(!found.contains { $0.kind == .date }, "\(found.map(\.description))")
        // The scheduled sentencing is not a sentencing date either.
        let names = CaseContradictionFinder.Names(documents: [a])
        let s = "The remaining two defendants in the case, Vernell Burris Jr. and Brian Kelly, have pleaded guilty and will be sentenced on Feb. 25, 2014."
        #expect(CaseContradictionFinder.stepDates(s, doc: 0, mentions: names.mentions(in: s, doc: 0), names: names).isEmpty)
        for scheduled in ["Brian Kelly is scheduled to be sentenced on Feb. 25, 2014.",
                          "Brian Kelly pleaded guilty, and his sentencing is set to take place on Feb. 25, 2014.",
                          "Brian Kelly pleaded guilty, with a hearing on Feb. 25, 2014."] {
            #expect(CaseContradictionFinder.stepDates(scheduled, doc: 0, mentions: names.mentions(in: scheduled, doc: 0), names: names).isEmpty, "\(scheduled)")
        }
    }

    @Test("A date the step's own verb governs still makes a date contradiction")
    func ownDateStillCounts() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Brian Kelly, 50, of Boca Raton, pleaded guilty on May 2, 2013, to conspiracy.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Brian Kelly, 50, of Boca Raton, pleaded guilty on June 2, 2013, to conspiracy.")
        let found = CaseContradictionFinder.ruleFindings([a, b])
        #expect(found.contains { $0.kind == .date && $0.attribute == "date pleaded guilty" }, "\(found.map(\.description))")
    }

    // MARK: - The bench footer

    @Test("The bench footer names the cloud readers that ran, the calls each made and the first failure")
    func benchSummary() {
        typealias S = CaseBenchRunner.ShardSummary
        #expect(S.cloudSummary(model: nil, readers: [:]) == "cloud readers: none")
        #expect(S.cloudSummary(model: "claude-opus-5", readers: [:]) == "cloud readers (claude-opus-5): installed, no calls made")
        let line = S.cloudSummary(model: "claude-opus-5", readers: [
            "draftReader": .init(calls: 1, failed: 1, failures: ["The provider's reply was cut off at the output limit before any answer text (x)."]),
            "contradictionReader": .init(calls: 7, failed: 0, failures: []),
            "roleReader": .init(calls: 0, failed: 0, failures: []),
        ])
        #expect(line == "cloud readers (claude-opus-5): contradictionReader 7 call(s), draftReader 1 call(s) (1 failed: The provider's reply was cut off at the output limit before any answer text (x).)")
    }
}
