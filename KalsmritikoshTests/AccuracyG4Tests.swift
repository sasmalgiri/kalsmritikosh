//
//  AccuracyG4Tests.swift
//  KalsmritikoshTests
//
//  Accuracy G4 (FAIR4 §5 item 2, 2026-11-25): "4X" (4X Solutions), "3M", "7-Eleven" — a digit glued to letters that a
//  document writes as a name is not a number; and the conclusion check also accepts what the second look got verified.
//  FAIR4 real4-4x q6: the claim "The court ordered 4X and Chay … $2,745,226 … $8,235,678" was dropped ("the number 4 not in
//  the quote") and the honest "Not established" conclusion withheld.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy G4 — names with digits; conclusion backed by the second look")
struct AccuracyG4Tests {
    typealias C = VerifiedAnswerComposer
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AgentEvalReal4/real4-4x")

    static func documents() throws -> [CaseReader.Document] {
        try ["4x-2013-04-08-cftc-release-6559-13.txt", "4x-2016-02-08-cftc-release-7321-16.txt"].map {
            CaseReader.Document(objectID: UUID(), fileName: $0, text: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    static let question = "How much restitution was ordered for the defrauded pool participants?"
    static let conclusion = "Not established — the documents give no restitution amount. The CFTC said it sought restitution, but the court order described is for disgorgement of $2,745,226 and a civil monetary penalty of $8,235,678, and the CFTC warns disgorgement may not result in recovery."
    static let questionReply = """
    {"status": "answered", "answers_question": "\(question)", "conclusion": "\(conclusion)", "claims": [\
    {"text": "In its litigation the CFTC said it sought restitution to defrauded customers, among other remedies.", "quote": "In its continuing litigation, the CFTC seeks restitution to defrauded customers, disgorgement of ill-gotten gains, civil monetary penalties", "passage": 1, "about": "CFTC"}, \
    {"text": "The court ordered 4X and Chay jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678; no restitution order is mentioned.", "quote": "jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678", "passage": 2, "about": "4X Solutions, Inc"}]}
    """
    static let lookReply = """
    {"status": "answered", "claims": [{"text": "On January 29, 2016 the court ordered the defendants jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678.", "quote": "on January 29, 2016, the Honorable Richard M. Berman, U.S. District Judge for the U.S. District Court for the Southern District of New York, ordered Defendants 4X Solutions, Inc . (4X) and its principal, Whileon Chay , both of New York City, jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678", "passage": 2}]}
    """

    @Test("G4: 4x q6 — the 4X claim is kept (the document writes 4X as a name)")
    func fourXClaim() throws {
        let p = CaseReader.passages(try Self.documents())
        #expect(C.whyNot(C.Claim(text: "The court ordered 4X and Chay jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678; no restitution order is mentioned.",
                                 quote: "jointly and severally to disgorge $2,745,226 and pay a civil monetary penalty of $8,235,678", passage: 2, about: "4X Solutions, Inc"),
                         passages: p) == nil)
        // A real count glued to x is still a number; "$10M" stays an amount; a name the documents never write stays a number.
        #expect(C.strippingNameTokens("BW-V900 4x units", sources: ["4x"]) == "BW-V900 4x units")
        let threeM = C.strippingNameTokens("paid $10M to 3M", sources: ["3M Company paid $10M"])
        #expect(threeM.contains("$10M") && !threeM.contains("3M"), "\(threeM)")
        #expect(C.strippingNameTokens("sold at 7-Eleven", sources: ["a 7-Eleven store"]).trimmingCharacters(in: .whitespaces) == "sold at")
        #expect(C.strippingNameTokens("4X ordered", sources: ["nothing here"]) == "4X ordered")
    }

    @Test("G4: 4x q6 — the conclusion is shown: its amounts are in the question's kept claim and in the second look's verified quote")
    func conclusionShown() throws {
        let docs = try Self.documents()
        guard case .answered(let a) = CaseReader.verdict(reply: Self.questionReply, question: Self.question, documents: docs, rules: nil, look: Self.lookReply) else {
            Issue.record("not answered"); return
        }
        #expect(a.body.hasPrefix(C.conclusionLabel), "\(a.body.prefix(300))")
        // Only the look backs the amounts: the question's own reply without its 4X claim.
        let onlyFirst = Self.questionReply.replacingOccurrences(of: #", \{"text": "The court ordered 4X.*\}\]\}"#, with: "]}", options: .regularExpression)
        guard case .answered(let without) = CaseReader.verdict(reply: onlyFirst, question: Self.question, documents: docs, rules: nil) else {
            Issue.record("not answered"); return
        }
        #expect(!without.body.hasPrefix(C.conclusionLabel), "without the look the amounts are unbacked")
        guard case .answered(let with) = CaseReader.verdict(reply: onlyFirst, question: Self.question, documents: docs, rules: nil, look: Self.lookReply) else {
            Issue.record("not answered"); return
        }
        #expect(with.body.hasPrefix(C.conclusionLabel), "the look's verified quote backs them: \(with.body.prefix(300))")
    }
}
