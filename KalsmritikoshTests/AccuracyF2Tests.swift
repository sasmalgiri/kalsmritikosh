//
//  AccuracyF2Tests.swift
//  KalsmritikoshTests
//
//  Accuracy F2 (FAIR3 root cause, 2026-11-25): money per party — in, out, kept (in − out), quoted balances, per currency —
//  in the briefing (stable) and, for trace / where / net / kept questions, the named parties' lines in the question task.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy F2 — money per party")
struct AccuracyF2Tests {
    static let d1 = UUID(), d2 = UUID(), d3 = UUID()

    static func money(_ from: String?, _ to: String?, _ amount: String, _ kind: String, date: String? = nil, doc: UUID = d1, text: String? = nil) -> CaseAIRecord {
        CaseAIRecord(kind: .fact, text: text ?? "\(from ?? "") → \(to ?? ""): \(amount) (\(kind))", entityType: CaseAIRecord.moneyType, role: kind,
                     dateText: date, from: from, to: to, relation: amount, quote: amount, document: doc, origin: "picture")
    }

    /// hard-kiln as the picture recorded it (names written four ways for Pemberton).
    static let kiln: [CaseAIRecord] = [
        money("Bradley J Kerr (NAB ****0457)", "Pemberton Wholesale Pty Ltd (****6610)", "350000.00", "transfer", date: "08/07/2026"),
        money("Pemberton Wholesale", "Kiln Street Logistics (****2290)", "350000.00", "payment", date: "09/07/2026", doc: d2),
        money("Southern Cross Mutual", "Kiln Street Logistics (****2290)", "900000.00", "payment", date: "30/07/2026", doc: d2),
        money("Kiln Street Logistics (****2290)", "Pemberton Wholesale (Westpac ****6610)", "350000.00", "refund", date: "03/08/2026", doc: d2),
        money("Pemberton Wholesale Pty Ltd", "Bradley J Kerr (NAB ****0457)", "280000.00", "transfer", date: "06/08/2026", doc: d3),
        money("Southern Cross Mutual Insurance", "Kiln Street Logistics Pty Ltd", "AUD 2,400,000", "claim"),
    ]

    @Test("F2: each party's in, out and kept; one party written four ways is one party; a mention is never a movement")
    func kilnFlows() throws {
        let flows = CaseAIUnderstanding.partyFlows(Self.kiln)
        let pemberton = try #require(flows.first { $0.name.hasPrefix("Pemberton") })
        #expect(pemberton.names.count == 4)
        #expect(pemberton.inTotals[""] == 700_000)
        #expect(pemberton.outTotals[""] == 630_000)
        #expect(pemberton.keptTotals[""] == 70_000)
        let kerr = try #require(flows.first { $0.name.hasPrefix("Bradley") })
        #expect(kerr.keptTotals[""] == -70_000)
        let kiln = try #require(flows.first { $0.name.hasPrefix("Kiln Street") })
        #expect(kiln.inTotals[""] == 1_250_000, "the claim (a mention) is not money in")
        let insurer = try #require(flows.first { $0.name == "Southern Cross Mutual" })
        #expect(insurer.kept == nil, "a payer only keeps nothing to compute")
        let line = CaseAIUnderstanding.flowLine(pemberton, number: [Self.d1: 1, Self.d2: 2, Self.d3: 3])
        #expect(line.contains("kept (in − out) 700,000 − 630,000 = 70,000"), "\(line)")
        #expect(line.hasSuffix("[D1] [D2] [D3]"))
    }

    @Test("F2: different account tails are different parties; currencies are never mixed; balances are quoted per party")
    func accountsCurrenciesBalances() throws {
        let recs = [
            Self.money("Hanley & Moore client account (5150)", "Ardmore Project Services Ltd (****2218)", "600000.00", "payment"),
            Self.money("Ardmore Project Services Ltd (****2218)", "Tidewell Holdings BV (NL91INGB0007781234)", "EUR 550,000", "transfer"),
            Self.money("Tidewell Holdings B.V.", "Hanley & Moore Solicitors client account", "€ 500.000,00", "transfer"),
            Self.money("Ardmore Project Services Ltd (****9999)", "Someone", "USD 10", "payment"),
            Self.money(nil, "Hanley & Moore client account (5150)", "1,800,000.00", "balance", date: "30/09/2026", text: "Hanley & Moore client account: 1,800,000.00 (balance), ref closing balance"),
        ]
        let flows = CaseAIUnderstanding.partyFlows(recs)
        let ardmores = flows.filter { $0.name.hasPrefix("Ardmore") }
        #expect(ardmores.count == 2, "****2218 and ****9999 are two accounts")
        let tidewell = try #require(flows.first { $0.name.hasPrefix("Tidewell") })
        #expect(tidewell.names.count == 2, "BV and B.V. are one name")
        #expect(tidewell.keptTotals["EUR"] == 50_000)
        let hanley = try #require(flows.first { $0.name.hasPrefix("Hanley") })
        #expect(hanley.names.count == 2, "the client account named with and without 'Solicitors' is one party")
        #expect(hanley.balances == ["30/09/2026 1,800,000.00 (closing balance)"])
        // Mixed currencies are kept apart.
        let mixed = CaseAIUnderstanding.partyFlows([Self.money("A Co", "B Co Ltd", "USD 100", "payment"), Self.money("B Co", "C Co", "EUR 40", "payment")])
        let b = try #require(mixed.first { $0.name.hasPrefix("B Co") })
        #expect(b.keptTotals == ["USD": 100, "EUR": -40])
        #expect(CaseAIUnderstanding.flowLine(b, number: [:]).contains("kept (in − out, per currency)"))
    }

    @Test("F2: the briefing shows money by party and no cross-party net outflow; it is the same for every question")
    func briefingSection() {
        var m = CaseLedgerBriefing.Material()
        m.aiRecords = Self.kiln
        let number = [Self.d1: 1, Self.d2: 2, Self.d3: 3]
        let b = CaseLedgerBriefing.build(m, number: number)
        #expect(b.text.contains("## " + CaseLedgerBriefing.partyMoneyTitle))
        #expect(b.text.contains("kept (in − out) 700,000 − 630,000 = 70,000"))
        #expect(!b.text.contains("Net outflow"))
        #expect(CaseLedgerBriefing.build(m, number: number).text == b.text)
    }

    @Test("F2: a trace / where / net / kept question gets the named parties' lines (else the intermediaries) in its task only")
    func questionTask() {
        let number = [Self.d1: 1, Self.d2: 2, Self.d3: 3]
        let lines = CaseAIUnderstanding.questionMoneyLines("Trace the money that moved between Bradley Kerr, Pemberton Wholesale and Kiln Street Logistics.",
                                                           records: Self.kiln, number: number)
        #expect(lines.contains { $0.hasPrefix("- Pemberton") && $0.contains("= 70,000") })
        #expect(lines.contains { $0.hasPrefix("- Bradley J Kerr") })
        #expect(lines.contains { $0.hasPrefix("- Kiln Street") })
        #expect(!lines.contains { $0.hasPrefix("- Southern Cross Mutual:") }, "not named and not an intermediary")
        #expect(CaseAIUnderstanding.questionMoneyLines("Who owned stock lots 14 to 39 when the fire broke out?", records: Self.kiln, number: number).isEmpty)
        #expect(CaseAIUnderstanding.asksMoneyTrace("How much did Deepline pay Bluewater in net terms?"))
        #expect(CaseAIUnderstanding.asksMoneyTrace("Where did the $180,000 go?"))
        #expect(!CaseAIUnderstanding.asksMoneyTrace("Was Okafor at the meeting on 2 February?"))
        // The task carries the lines; without them it is unchanged.
        let task = CaseReader.partSuffix("Q?", related: [], toolsAllowed: false, toolResults: nil, notes: lines)
        #expect(task.contains(CaseReader.taskNotesLead))
        #expect(CaseReader.partSuffix("Q?", related: [], toolsAllowed: false, toolResults: nil)
                == CaseReader.partSuffix("Q?", related: [], toolsAllowed: false, toolResults: nil, notes: []))
    }
}
