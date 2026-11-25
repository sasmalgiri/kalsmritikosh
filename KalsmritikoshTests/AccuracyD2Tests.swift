//
//  AccuracyD2Tests.swift
//  KalsmritikoshTests
//
//  Accuracy D2 (FAIR5 §6 item 2, 2026-11-25): a compare_dates day count is the app's arithmetic, like a sum — shown under
//  the answer, and a conclusion's "9 days" may come from it (FAIR5 harbor q3, meridian q3/q6, siddiqui q7 were withheld).
//  Any date style; negatives: a date no document writes, a missing day or year, and a wrong day count stay unbacked.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy D2 — compare_dates results are the app's arithmetic")
struct AccuracyD2Tests {
    typealias C = VerifiedAnswerComposer

    static func tools(_ texts: [String]) -> CaseAgentTools {
        CaseAgentTools(documents: texts.enumerated().map { CaseReader.Document(objectID: UUID(), fileName: "d\($0.offset + 1).txt", text: $0.element) })
    }
    static func compare(_ t: CaseAgentTools, _ a: String, _ b: String) async -> String {
        let reply = #"{"status": "need_tools", "requests": [{"tool": "compare_dates", "a": "\#(a)", "b": "\#(b)"}]}"#
        guard let calls = CaseAgent.parse(reply)?.calls else { return "" }
        return await t.run(calls)
    }

    @Test("Any date style: the day count is added to the app's arithmetic, earlier date first")
    func anyStyle() async {
        let pairs: [(String, String, Int)] = [("3 March 2026", "13 March 2026", 10), ("2026-03-04", "2026-03-13", 9),
                                              ("March 13, 2026", "March 4, 2026", 9), ("2 November 2023", "20 November 2023", 18),
                                              ("1 Feb 2024", "1 Mar 2024", 29)]
        for (a, b, n) in pairs {
            let t = Self.tools(["Ledger posted on \(a).", "The wire went on \(b)."])
            _ = await Self.compare(t, a, b)
            #expect(t.arithmetic.count == 1, "\(a) / \(b)")
            #expect(t.arithmetic.first?.hasSuffix("= \(n) days") == true, "\(t.arithmetic)")
            // The earlier date is written first.
            let earlierFirst = (CaseLedgerBriefing.days(from: C.values(in: a).dates[0], to: C.values(in: b).dates[0]) ?? 0) >= 0
            #expect(t.arithmetic.first?.hasPrefix("\u{201C}" + (earlierFirst ? a : b)) == true, "\(t.arithmetic)")
        }
    }

    @Test("Not arithmetic: a date no document writes, or a day or year missing")
    func negatives() async {
        let t = Self.tools(["Ledger posted on 4 March 2026.", "The wire went on 13 March 2026."])
        _ = await Self.compare(t, "4 March 2026", "20 March 2026")
        _ = await Self.compare(t, "March 2026", "13 March 2026")
        _ = await Self.compare(t, "4 March", "13 March 2026")
        #expect(t.arithmetic.isEmpty, "\(t.arithmetic)")
    }

    @Test("FAIR5 harbor q3: the conclusion's '9 days' is shown with the day count; a wrong count is still withheld")
    func conclusion() async {
        let t = Self.tools(["Posting date: 2026-03-04 — BMC-0311 consulting fee 180,000.00", "2026-03-13, Outgoing wire - BMC-0311, 180000.00"])
        _ = await Self.compare(t, "2026-03-04", "2026-03-13")
        let claims = [C.VerifiedClaim(text: "The ledger posted BMC-0311 on 2026-03-04.", quote: "Posting date: 2026-03-04 — BMC-0311 consulting fee 180,000.00", passage: 1),
                      C.VerifiedClaim(text: "The wire went on 2026-03-13.", quote: "2026-03-13, Outgoing wire - BMC-0311, 180000.00", passage: 2)]
        let passages = CaseReader.passages(t.documents)
        #expect(C.conclusionWithheld("The ledger date 2026-03-04 is 9 days before the 2026-03-13 wire.", claims: claims, arithmetic: t.arithmetic, passages: passages) == nil)
        #expect(C.conclusionWithheld("The ledger date 2026-03-04 is 9 days before the 2026-03-13 wire.", claims: claims, arithmetic: [], passages: passages) != nil,
                "without the tool's line the count is unbacked")
        #expect(C.conclusionWithheld("The ledger date 2026-03-04 is 8 days before the 2026-03-13 wire.", claims: claims, arithmetic: t.arithmetic, passages: passages) != nil)
    }
}
