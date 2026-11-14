//
//  AnswerPathOnTargetTests.swift
//  KalsmritikoshTests
//
//  Real-case v2 interim review (2026-11-04), three answer-path defects, reproduced with the shapes the
//  investigators quoted (fake reader closures, small fixtures — no model, no network):
//    1. a correct verified AI answer flagged "Needs review" against an off-target evidence-only reading;
//    2. offline off-target passages at confidence 0.8, and "History of the user's archive" dumps for
//       ordinary questions;
//    3. a failed cloud call explained only in the run summary ("the AI reader did not answer").
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Answer path — on-target evidence, honest failures")
struct AnswerPathOnTargetTests {
    typealias C = VerifiedAnswerComposer
    typealias T = EvidenceOnTarget

    static let release03 = C.Passage(objectID: UUID(), text: """
        Date: 12/12/2013. On the night of February 1, 2012, Guy Miller, 39, of Logan, along with Shawn C. Simon, 41, of Charleston \
        and Michael Williams, 44, of Logan, worked together to set the fire to the building by spreading gasoline throughout the main floor.
        """, fileName: "release-03-2013-12-12.eml")
    static let release01 = C.Passage(objectID: UUID(), text: """
        A 36-count indictment was unsealed today, charging James Gregory Glick, Guy R. Miller, Shawn C. Simon and William Jamey Thompson \
        with conspiracy to commit arson, conspiracy to commit mail and wire fraud.
        """, fileName: "release-01-2013-09-03.pdf")

    static func reply(_ claims: [(String, String, Int)]) -> String {
        let items = claims.map { ["text": $0.0, "quote": $0.1, "passage": $0.2] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: ["status": "answered", "claims": items, "answer": "x"] as [String: Any])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func rules(_ text: String, snippet: String? = nil, objectID: UUID = UUID(), confidence: Double = 0.8) -> VerifiedAnswer {
        VerifiedAnswer(body: text + "\n\n(Quoted verbatim from the cited document; no model was consulted.)", answerText: text,
                       citations: [.init(objectID: objectID, snippet: snippet ?? text)], confidence: Confidence(confidence))
    }

    // MARK: - 1. Cross-check against an off-target rules reading

    @Test("1: 'Date: 12/12/2013.' for 'When was the fire set?' is no competing value — the verified AI answer ships")
    func headerDateIsNotADisagreement() {
        let r = Self.reply([("The fire was set on the night of February 1, 2012.",
                             "On the night of February 1, 2012, Guy Miller, 39, of Logan, along with Shawn C. Simon", 1)])
        let o = C.decide(reply: r, question: "When was the fire set?", passages: [Self.release03], person: nil,
                         rules: Self.rules("Date: 12/12/2013.", snippet: "2013-12-12", objectID: Self.release03.objectID))
        guard case .answered(let a) = o else { Issue.record("expected an answer, got \(o)"); return }
        #expect(C.writer(of: a) == "ai-verified", "\(a.body)")
        #expect(!a.body.hasPrefix("Needs review"))
        #expect(!a.body.contains("Evidence-only reading"))
        #expect(a.body.contains(C.offTargetNote))
        #expect(a.contradictions.isEmpty)
    }

    @Test("1: a sentencing sentence for 'Who was charged …?' and an e-mail address for 'When did … learn …?' are off target")
    func offTargetRulesShapes() {
        let charged = C.decide(
            reply: Self.reply([("A 36-count indictment charged James Gregory Glick, Guy R. Miller, Shawn C. Simon and William Jamey Thompson.",
                                "A 36-count indictment was unsealed today, charging James Gregory Glick, Guy R. Miller, Shawn C. Simon and William Jamey Thompson", 1)]),
            question: "Who was charged over the burning of the office building in Logan?", passages: [Self.release01], person: nil,
            rules: Self.rules("The document states: \u{201C}On Wednesday, Guy R. Miller, Jr., 40, of Logan, was sentenced to six years and three months in prison for his role in facilitating the February 1, 2012 burning of a former law office building located at 111 Stratton Street in downtown Logan.\u{201D}"))
        guard case .answered(let a) = charged else { Issue.record("expected an answer"); return }
        #expect(C.writer(of: a) == "ai-verified", "\(a.body)")

        let lay = C.Passage(objectID: UUID(), text: "An unsigned letter was written in August to Kenneth L. Lay, chairman of Enron, after Jeffrey K. Skilling resigned on Aug. 14.")
        let learned = C.decide(
            reply: Self.reply([("A letter was written in August to Kenneth L. Lay after Skilling resigned on Aug. 14.",
                                "An unsigned letter was written in August to Kenneth L. Lay, chairman of Enron, after Jeffrey K. Skilling resigned on Aug. 14.", 1)]),
            question: "When did Kenneth Lay learn of the accounting concerns?", passages: [lay], person: nil,
            rules: Self.rules("timothy.hubbard@enron.com\nkenneth.lay@enron.com\nConcern about EBS"))
        guard case .answered(let b) = learned else { Issue.record("expected an answer"); return }
        #expect(C.writer(of: b) == "ai-verified", "\(b.body)")
    }

    @Test("1: a genuine disagreement (both on target, different dates) still needs review with both")
    func genuineDisagreementKept() {
        let mignott = C.Passage(objectID: UUID(), text: "Harold Mignott, 45, of Buffalo, was sentenced on Feb. 1, 2023 to 72 months in prison.")
        let o = C.decide(reply: Self.reply([("Harold Mignott was sentenced on February 1, 2023.", "was sentenced on Feb. 1, 2023 to 72 months in prison", 1)]),
                         question: "When was Harold Mignott sentenced?", passages: [mignott], person: "Harold Mignott",
                         rules: Self.rules("Harold Mignott was sentenced on February 2, 2023."))
        guard case .answered(let a) = o else { Issue.record("expected an answer"); return }
        #expect(C.writer(of: a) == "needs-review")
        #expect(a.body.contains("Evidence-only reading: Harold Mignott was sentenced on February 2, 2023."))
    }

    @Test("1: only the asked kind of value disagrees — ages in a who-answer do not, a different person does")
    func askedValuesOnly() {
        let q = "Who was charged together with John L. Hutchins?"
        #expect(!C.disagree(aiText: "John L. Hutchins, 68, and Roberto Soliman, 39, were charged by indictment.",
                            rules: Self.rules("Roberto Soliman, 45, was charged with John L. Hutchins."), question: q))
        #expect(C.disagree(aiText: "Roberto Soliman was charged with him.", rules: Self.rules("Patricia Hutchins was charged with him."), question: q))
        #expect(C.disagree(aiText: "He was sentenced to three years in prison.", rules: Self.rules("He was sentenced to six years in prison."),
                           question: "What sentence did Harold Mignott receive?"))
        #expect(!C.disagree(aiText: "The defendants agreed to defraud the victim company of approximately $1 million in 2016.",
                            rules: Self.rules("Douglas was scheduled to be sentenced on July 26, 2023."), question: "What was Jerrid Douglas's role in the scheme?"))
    }

    @Test("1: a proceeding cross-check never 'confirms' an off-target rules value")
    func crossCheckedOffTarget() async {
        let composer = C(generate: { _, _ in
            Self.reply([("Hutchins pleaded guilty on March 20, 2025.", "John L. Hutchins pleaded guilty on March 20, 2025 before Judge Meredith A. Vacca", 1)])
        })
        let passage = C.Passage(objectID: UUID(), text: "John L. Hutchins pleaded guilty on March 20, 2025 before Judge Meredith A. Vacca to conspiracy.")
        // The rules' date is the document's dateline, not in its quote (the headline).
        let rules = Self.rules("The document dated March 21, 2025 reports that John L. Hutchins was pleaded guilty; it gives no other day: \u{201C}Rapids Theatre owner pleads guilty to defrauding COVID relief programs\u{201D}",
                               snippet: "Rapids Theatre owner pleads guilty to defrauding COVID relief programs")
        let o = await composer.compose(question: "When did John L. Hutchins plead guilty?", passages: [passage], rules: rules, clearance: nil)
        let checked = C.crossChecked(o, rules: rules)
        #expect(checked.map(C.writer(of:)) == "ai-verified", "\(checked?.body ?? "nil")")
        #expect(checked?.body.contains("Confirmed by the AI reading") == false)
    }

    // MARK: - 2. Offline: off-target passages, history dumps

    static func chunk(_ text: String, object: UUID = UUID()) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: object, ordinal: 0, text: text, characterRange: 0..<text.count), score: 1, viaLayer: .metadata)
    }

    static func quoted(_ sentence: String, object: UUID) -> VerifiedAnswer {
        let body = SentenceQuoteComposer.render(QuotedAnswer(sentence: sentence, objectID: object, chunkID: UUID(), receiptLine: "x"))
        return VerifiedAnswer(body: body + "\n\n(Quoted verbatim from the cited document; no model was consulted.)", answerText: body,
                              citations: [.init(objectID: object, snippet: sentence)], confidence: Confidence(0.8))
    }

    @Test("2: 'How experienced was the pilot?' answered by a descent sentence is the closest passage, well below 0.8")
    func experienceQuestionOffTarget() {
        let doc = UUID()
        let s = "Shortly after, she asked the two-aircraft flight to expedite its descent to 3,000 ft and noticed that the Cessna was climbing above 1,000 ft."
        let a = T.checked(question: "How experienced was the Cessna pilot and was he medically qualified?", Self.quoted(s, object: doc), chunks: [Self.chunk(s, object: doc)])
        #expect(a.body.hasPrefix(T.closestMarker), "\(a.body)")
        #expect(a.confidence.value <= 0.3)
        #expect(!a.refused && !a.citations.isEmpty, "the passage stays visible")
        let good = "The Cessna pilot held a private pilot certificate and had about 2,000 total hours of flight experience."
        let b = T.checked(question: "How experienced was the Cessna pilot?", Self.quoted(good, object: doc), chunks: [Self.chunk(good, object: doc)])
        #expect(b.body == Self.quoted(good, object: doc).body && b.confidence.value == 0.8)
    }

    @Test("2: a report's title line is not an answer to a quantity question")
    func titleLineOffTarget() {
        let doc = UUID()
        let title = "FDA Enforcement Report — recall event 70738 Blue Bell Creameries, L.P. — 286 product record(s)"
        let a = T.checked(question: "What is the total quantity of product recalled in recall event 70738?", Self.quoted(title, object: doc),
                          chunks: [Self.chunk(title, object: doc)])
        #expect(a.body.hasPrefix(T.closestMarker + " (it is a title line)"), "\(a.body)")
    }

    @Test("2: a 2021 recall's passage for an April 2015 question is another record; the 2015 record's is kept")
    func wrongRecordOffTarget() {
        let q = "How many cases of Sabra hummus were recalled in April 2015?"
        let line = "Expiration date 4/26/21 | 2160 cases, 16,200 lbs | 300067."
        let doc2021 = UUID()
        let a = T.checked(question: q, Self.quoted(line, object: doc2021),
                          chunks: [Self.chunk("Event ID: 87614 Recall initiation date: March 26, 2021. " + line, object: doc2021)])
        #expect(a.body.hasPrefix(T.closestMarker), "\(a.body)")
        #expect(a.body.contains("April 2015"))
        let doc2015 = UUID()
        let b = T.checked(question: q, Self.quoted(line, object: doc2015),
                          chunks: [Self.chunk("Event ID: 70934 Recall initiation date: April 7, 2015. " + line, object: doc2015)])
        #expect(!b.body.hasPrefix(T.closestMarker), "\(b.body)")
        #expect(b.confidence.value == 0.8)
    }

    @Test("2: only an explicit history ask takes the history path")
    func historyOnlyWhenAsked() {
        #expect(MasterBrain.asksForHistory("Reconstruct the history of Project Delta."))
        #expect(MasterBrain.asksForHistory("What happened in Project Delta?"))
        #expect(MasterBrain.asksForHistory("Give me the timeline of the Logan arson case."))
        #expect(!MasterBrain.asksForHistory("How many people were killed or injured in the collision, and what happened to the F-16 pilot?"))
        #expect(!MasterBrain.asksForHistory("What happened to the digital video recorder?"))
        #expect(!MasterBrain.asksForHistory("Is Maurice Mills connected to the Mohamed Kamara case?"))
        #expect(!MasterBrain.asksForHistory("How much money did Glick structure or move through Logan Bank & Trust?"))
    }

    // MARK: - 3. A failed cloud call, explained

    static func http(_ status: Int, _ json: String) -> OutboundHTTPResponse { OutboundHTTPResponse(status: status, body: Data(json.utf8)) }

    @Test("3: provider replies classified — no credit, key refused, rate limited, network, timeout, cut off, declined")
    func classification() {
        let credit = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#
        func failure(_ r: OutboundHTTPResponse) -> OnlineFailure {
            do { _ = try OnlineRequestBuilder.parse(kind: .anthropic, response: r); return .other } catch { return OnlineFailure.classify(error) }
        }
        #expect(failure(Self.http(400, credit)) == .noCredit)
        #expect(failure(Self.http(402, #"{"type":"error","error":{"type":"billing_error","message":"Payment problem"}}"#)) == .noCredit)
        #expect(failure(Self.http(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)) == .invalidKey)
        #expect(failure(Self.http(429, "{}")) == .rateLimited)
        #expect(failure(Self.http(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)) == .providerError)
        #expect(OnlineFailure.classify(URLError(.notConnectedToInternet)) == .network)
        #expect(OnlineFailure.classify(NetworkHelperError.failed("connection lost")) == .network)
        #expect(OnlineFailure.classify(OnlineCloudProvider.OnlineError.timedOut) == .timeout)
        #expect(OnlineFailure.classify(OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking")) == .cutOff)
        #expect(OnlineFailure.classify(OnlineCloudProvider.OnlineError.declined) == .declined)
        #expect(OnlineFailure.noCredit.banner == "Your AI account has no credit — answers are evidence-only until it is topped up.")
        #expect(OnlineFailure.timeout.banner == nil)
    }

    @Test("3: the answer's note carries the classified reason and the provider's words — never the key")
    func failureNoteInAnswer() async {
        let credit = OnlineRequestBuilder.ParseError.http(400, "Your credit balance is too low to access the Anthropic API.")
        let composer = C(generate: { _, _ in throw credit })
        let rules = Self.rules("Harold Mignott was sentenced on February 1, 2023.")
        let passage = C.Passage(objectID: UUID(), text: "Harold Mignott was sentenced on Feb. 1, 2023 to 72 months in prison.")
        let o = await composer.compose(question: "When was Harold Mignott sentenced?", passages: [passage], rules: rules, clearance: nil)
        guard case .failed(let reason) = o else { Issue.record("expected failed, got \(o)"); return }
        #expect(reason.contains("your AI account has no credit"), "\(reason)")
        #expect(reason.contains("Your credit balance is too low"))
        let shown = C.flagged(rules, reason: reason)
        #expect(shown.body.contains("(The AI reading could not be used — your AI account has no credit"), "\(shown.body)")
        #expect(!shown.body.contains("the AI reader did not answer"))
        // A provider message that echoes a key-shaped string is scrubbed.
        let echoed = OnlineFailure.note(for: OnlineRequestBuilder.ParseError.http(401, "invalid x-api-key sk-ant-api03-ABCDEFGHIJKLMNOPQRST"))
        #expect(!echoed.contains("sk-ant-api03-ABCDEFGHIJKLMNOPQRST") && echoed.contains("[key hidden]"), "\(echoed)")
    }

    @Test("3: the Online status keeps the account-level banner until dismissed")
    @MainActor func statusBanner() {
        let status = OnlineStatus()
        status.recordFailure("The provider returned HTTP 400: Your credit balance is too low", kind: .noCredit)
        #expect(status.accountBanner == OnlineFailure.noCredit.banner)
        status.recordFailure("The provider did not reply in time.", kind: .timeout)
        #expect(status.accountBanner == nil)
        status.clear()
        #expect(status.lastFailure == nil && status.lastFailureKind == nil)
    }
}
