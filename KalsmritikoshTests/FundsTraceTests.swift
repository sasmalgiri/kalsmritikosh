//
//  FundsTraceTests.swift
//  KalsmritikoshTests
//
//  A-8 — amount-weighted funds tracing (pure logic, no database). Proves: amounts are tied to a
//  payment only when the document is unambiguous; currencies are never added together; per-party
//  in/out/net; the follow-the-money trace caps each hop by what the payer received in the trace and
//  says where money stops; every figure carries its fact and document ids. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("A-8 — funds tracing")
struct FundsTraceTests {

    private func edge(_ f: String, _ t: String, _ docs: [String]) -> FundsPaymentEdge {
        FundsPaymentEdge(fromID: f, fromLabel: f, toID: t, toLabel: t, documentIDs: docs)
    }
    private func amount(_ id: String, _ doc: String, _ value: String, _ unit: String?) -> FundsAmountFact {
        FundsAmountFact(factID: id, documentID: doc, value: value, unit: unit)
    }
    private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }

    @Test("Amounts parse with their currency; a number without one stays UNSTATED")
    func parsesMoney() {
        #expect(FundsMoneyParser.parse(value: "₹10,000", unit: "INR") == FundsMoney(amount: 10_000, currency: "INR"))
        #expect(FundsMoneyParser.parse(value: "Rs. 5,00,000", unit: nil) == FundsMoney(amount: 500_000, currency: "INR"))
        #expect(FundsMoneyParser.parse(value: "$1,234.56", unit: nil) == FundsMoney(amount: d("1234.56"), currency: "USD"))
        #expect(FundsMoneyParser.parse(value: "1500", unit: nil) == FundsMoney(amount: 1500, currency: FundsMoney.unstated))
        #expect(FundsMoneyParser.parse(value: "no figure", unit: "USD") == nil)
        #expect(FundsMoneyParser.parse(value: "0", unit: "USD") == nil)
    }

    @Test("An amount is assigned only when one document backs one payment with one amount")
    func attributionIsNeverGuessed() {
        let edges = [edge("A", "B", ["D1", "D2", "D3"]), edge("A", "C", ["D3"]), edge("C", "B", ["D4"])]
        let amounts = [amount("f1", "D1", "₹100", "INR"), amount("f1b", "D1", "100", nil),   // same figure twice → one amount
                       amount("f2", "D2", "₹100", "INR"), amount("f2b", "D2", "₹250", "INR"), // two figures
                       amount("f3", "D3", "₹70", "INR")]                                       // two payments in D3
        let r = FundsTrace.attribute(edges: edges, amounts: amounts)
        #expect(r.transfers.count == 1)
        #expect(r.transfers.first?.documentID == "D1")
        #expect(r.transfers.first?.factIDs == ["f1", "f1b"])
        #expect(r.transfers.first?.money == FundsMoney(amount: 100, currency: "INR"))
        let reasons = Dictionary(uniqueKeysWithValues: r.unattributed.map { ($0.documentID, $0.reason) })
        #expect(reasons["D2"] == .severalAmounts)
        #expect(reasons["D3"] == .severalPayments)
        #expect(reasons["D4"] == .noAmount)
    }

    @Test("Edge totals and party balances are per currency — different currencies are never added")
    func mixedCurrenciesStaySeparate() {
        let edges = [edge("A", "B", ["D1"]), edge("A", "B", ["D2"]), edge("A", "B", ["D3"]), edge("B", "C", ["D4"])]
        let amounts = [amount("f1", "D1", "₹1,000", "INR"), amount("f2", "D2", "₹500", "INR"),
                       amount("f3", "D3", "$40", "USD"), amount("f4", "D4", "₹300", "INR")]
        let t = FundsTrace.attribute(edges: edges, amounts: amounts).transfers
        let totals = FundsTrace.edgeTotals(t)
        let ab = totals.filter { $0.fromID == "A" && $0.toID == "B" }
        #expect(ab.count == 2)
        let inr = ab.first { $0.currency == "INR" }
        #expect(inr?.total == 1500)
        #expect(inr?.transferCount == 2)
        #expect(inr?.factIDs == ["f1", "f2"])
        #expect(inr?.documentIDs == ["D1", "D2"])
        #expect(ab.first { $0.currency == "USD" }?.total == 40)

        let balances = FundsTrace.partyBalances(t)
        let bINR = balances.first { $0.partyID == "B" && $0.currency == "INR" }
        #expect(bINR?.received == 1500)
        #expect(bINR?.sent == 300)
        #expect(bINR?.net == 1200)
        #expect(bINR?.documentIDs == ["D1", "D2", "D4"])
        let bUSD = balances.first { $0.partyID == "B" && $0.currency == "USD" }
        #expect(bUSD?.received == 40)
        #expect(bUSD?.sent == 0)
        #expect(balances.first { $0.partyID == "A" && $0.currency == "INR" }?.net == -1500)
    }

    @Test("A party cannot pass on more than it received in the trace; onward payments are capped proportionally")
    func traceCapsByReceivedAmount() {
        // A pays B 15,000. B is recorded paying C 12,000 and D 6,000 (18,000 > 15,000 received).
        let totals = [
            total("A", "B", 15_000, ["fAB"], ["D1"]), total("B", "C", 12_000, ["fBC"], ["D2"]),
            total("B", "D", 6_000, ["fBD"], ["D3"])
        ]
        let r = FundsTrace.trace(from: "A", currency: "INR", edges: totals)
        #expect(r.sentByOrigin == 15_000)
        let step = Dictionary(uniqueKeysWithValues: r.steps.map { ($0.id, $0) })
        #expect(step["A|B"]?.traced == 15_000)
        #expect(step["A|B"]?.capped == false)
        #expect(step["B|C"]?.traced == 10_000)       // 12/18 of 15,000
        #expect(step["B|C"]?.recorded == 12_000)
        #expect(step["B|C"]?.capped == true)
        #expect(step["B|D"]?.traced == 5_000)        // 6/18 of 15,000
        #expect(step["B|D"]?.depth == 2)
        #expect(step["B|C"]?.factIDs == ["fBC"])
        let stops = Dictionary(uniqueKeysWithValues: r.stops.map { ($0.partyID, $0) })
        #expect(stops["C"]?.amount == 10_000)
        #expect(stops["C"]?.reason == .noOnwardPayments)
        #expect(stops["C"]?.documentIDs == ["D2"])
        #expect(stops["D"]?.amount == 5_000)
        // Everything sent is accounted for: traced money ends at the stops.
        #expect(r.stops.reduce(Decimal(0)) { $0 + $1.amount } == r.sentByOrigin)
    }

    @Test("Money a party received but is not recorded passing on stops with it")
    func traceShowsWhereMoneyStops() {
        // A pays B 10,000; B passes on only 4,000 to C; C passes 4,000 to D.
        let totals = [total("A", "B", 10_000, ["f1"], ["D1"]), total("B", "C", 4_000, ["f2"], ["D2"]),
                      total("C", "D", 4_000, ["f3"], ["D3"])]
        let r = FundsTrace.trace(from: "A", currency: "INR", edges: totals)
        let kept = r.stops.first { $0.partyID == "B" }
        #expect(kept?.reason == .keptMoreThanPassedOn)
        #expect(kept?.amount == 6_000)
        #expect(kept?.factIDs == ["f1"])            // rests on the payment into B
        #expect(r.stops.first { $0.partyID == "D" }?.amount == 4_000)
        #expect(r.steps.map(\.depth) == [1, 2, 3])
    }

    @Test("Other currencies are ignored by a trace, a loop back to the origin stops there, and the hop limit is honoured")
    func traceCurrencyCycleAndDepth() {
        let totals = [total("A", "B", 1_000, ["f1"], ["D1"]), total("B", "A", 1_000, ["f2"], ["D2"]),
                      total("A", "X", 99, ["fx"], ["DX"], currency: "USD")]
        let r = FundsTrace.trace(from: "A", currency: "INR", edges: totals)
        #expect(r.sentByOrigin == 1_000)
        #expect(r.steps.allSatisfy { $0.toID != "X" })
        #expect(r.stops.first?.reason == .returnedToOrigin)
        #expect(r.stops.first?.amount == 1_000)

        let chain = [total("A", "B", 50, [], []), total("B", "C", 50, [], []), total("C", "D", 50, [], [])]
        let short = FundsTrace.trace(from: "A", currency: "INR", edges: chain, maxDepth: 2)
        #expect(short.stops.first?.partyID == "C")
        #expect(short.stops.first?.reason == .depthLimit)

        let both = FundsTrace.trace(from: "A", transfers: [
            FundsTransfer(fromID: "A", fromLabel: "A", toID: "B", toLabel: "B", money: FundsMoney(amount: 5, currency: "USD"), documentID: "D1", factIDs: ["f1"]),
            FundsTransfer(fromID: "A", fromLabel: "A", toID: "B", toLabel: "B", money: FundsMoney(amount: 7, currency: "INR"), documentID: "D2", factIDs: ["f2"])
        ])
        #expect(both.map(\.currency) == ["INR", "USD"])
        #expect(both.map(\.sentByOrigin) == [7, 5])
    }

    @Test("Display formatting rounds to two decimals and marks an unstated currency")
    func formatting() {
        #expect(FundsTrace.format(d("1234567.456"), currency: "INR") == "INR 1,234,567.46")
        #expect(FundsTrace.format(10, currency: FundsMoney.unstated) == "10 (currency not stated)")
    }

    private func total(_ f: String, _ t: String, _ amount: Decimal, _ facts: [String], _ docs: [String],
                       currency: String = "INR") -> FundsEdgeTotal {
        FundsEdgeTotal(fromID: f, fromLabel: f, toID: t, toLabel: t, currency: currency, total: amount,
                       transferCount: 1, factIDs: facts, documentIDs: docs)
    }
}
