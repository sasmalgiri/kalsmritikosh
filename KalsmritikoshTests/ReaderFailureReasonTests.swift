//
//  ReaderFailureReasonTests.swift
//  KalsmritikoshTests
//
//  Smoke 2026-11-03 (real case, Opus 5 readers): the case drafts made 0 drafting calls and "1 failed",
//  the role reader verified 0, the contradiction reader dropped 6 pairs — with no reason recorded
//  anywhere. Root cause of the failures: current Claude models think before answering and the thinking
//  counts against max_tokens, so a 1,500-token draft call spent all 1,500 on thinking and returned no
//  text. These tests pin: the thinking allowance on top of the reply budget; a cut-off reply named as
//  such; role readings and dropped AI contradiction pairs carrying their reasons; a date governed by a
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

    // MARK: - Contradiction reader drops

    @Test("Every dropped AI contradiction pair carries its reason and what it proposed")
    func contradictionDropReasons() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Brian M. Kelly, 50, of Boca Raton, received $120,000 from the scheme.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Kelly received $95,000 from homeowners, according to the plea agreement.")
        let batch = CaseContradictionFinder.Batch(subject: "Brian M. Kelly", passages: [a, b].map { .init(objectID: $0.objectID, text: $0.text) })
        let reply = """
            {"pairs": [
              {"about": "Brian M. Kelly", "kind": "amount", "a": {"passage": 1, "quote": "received $125,000 from the scheme"},
               "b": {"passage": 2, "quote": "Kelly received $95,000 from homeowners"}, "value_a": "$125,000", "value_b": "$95,000"},
              {"about": "Brian M. Kelly", "kind": "amount", "a": {"passage": 1, "quote": "received $120,000 from the scheme"},
               "b": {"passage": 3, "quote": "Kelly received $95,000 from homeowners"}, "value_a": "$120,000", "value_b": "$95,000"},
              {"about": "Brian M. Kelly", "kind": "amount", "a": {"passage": 1, "quote": "received $120,000 from the scheme"},
               "b": {"passage": 2, "quote": "Kelly received $95,000 from homeowners"}, "value_a": "$120,000", "value_b": "$95,000"}
            ]}
            """
        let v = CaseContradictionFinder.verify(reply: reply, batch: batch, allDocuments: [a, b])
        #expect(v.verified.count == 1, "\(v.dropped)")
        #expect(v.dropped.count == 2)
        #expect(v.dropped[0].hasPrefix("quote not in its passage — about Brian M. Kelly (amount): $125,000 [passage 1] vs $95,000 [passage 2]"), "\(v.dropped)")
        #expect(v.dropped[1].hasPrefix("passage not sent — ") && v.dropped[1].contains("[passage 3]"), "\(v.dropped)")
    }

    @Test("Ranges sharing an endpoint still differ; a statutory maximum is explained, not a contradiction")
    func rangesAndMaximums() {
        let a = CaseContradictionFinder.Document(objectID: UUID(), text: "Godfrey induced homeowners to pay HOPE up-front fees of $400 to $2,000 for its services.")
        let b = CaseContradictionFinder.Document(objectID: UUID(), text: "Godfrey induced homeowners to pay HOPE up-front fees of $400-$900 for its services.")
        let c = CaseContradictionFinder.Document(objectID: UUID(), text: "The charge of conspiracy carries a maximum penalty of five years in prison.")
        let d = CaseContradictionFinder.Document(objectID: UUID(), text: "Each count of wire fraud carries a maximum penalty of 20 years in prison.")
        let batch = CaseContradictionFinder.Batch(subject: nil, passages: [a, b, c, d].map { .init(objectID: $0.objectID, text: $0.text) })
        let reply = """
            {"pairs": [
              {"about": "HOPE up-front fees", "kind": "amount", "a": {"passage": 1, "quote": "up-front fees of $400 to $2,000"},
               "b": {"passage": 2, "quote": "up-front fees of $400-$900"}, "value_a": "$400 to $2,000", "value_b": "$400-$900"},
              {"about": "maximum penalty in prison", "kind": "amount", "a": {"passage": 3, "quote": "carries a maximum penalty of five years in prison"},
               "b": {"passage": 4, "quote": "carries a maximum penalty of 20 years in prison"}, "value_a": "five years", "value_b": "20 years"},
              {"about": "HOPE up-front fees", "kind": "amount", "a": {"passage": 1, "quote": "up-front fees of $400 to $2,000"},
               "b": {"passage": 2, "quote": "up-front fees of $400-$900"}, "value_a": "$400", "value_b": "$400"}
            ]}
            """
        let v = CaseContradictionFinder.verify(reply: reply, batch: batch, allDocuments: [a, b, c, d])
        #expect(v.verified.count == 1 && v.verified.first?.valueA == "$400 to $2,000", "\(v.dropped)")
        #expect(v.dropped.contains { $0.hasPrefix("explained: a maximum penalty") }, "\(v.dropped)")
        #expect(v.dropped.contains { $0.hasPrefix("the values do not differ") }, "\(v.dropped)")
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
