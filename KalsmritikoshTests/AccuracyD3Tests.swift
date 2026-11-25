//
//  AccuracyD3Tests.swift
//  KalsmritikoshTests
//
//  Accuracy D3 (FAIR5 §6 item 3, 2026-11-25): money by party de-duplicates one movement recorded twice within ONE document
//  (the AI recording a statement line from both parties' side: same amount, currency, day, parties, and the same quoted
//  line or reference) — and keeps genuinely repeated transactions (another line, another reference, another time of day).
//  FAIR5 harbor: Northgate out 1,400,000 ×2, Okafor in 95,000 ×2, Bluewater "kept" 110,000.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy D3 — one movement recorded twice in one document is counted once")
struct AccuracyD3Tests {
    static func rec(_ amount: String, _ from: String, _ to: String, _ date: String, ref: String?, quote: String, doc: UUID,
                    kind: String = "payment") -> CaseAIRecord {
        let text = "\(from) → \(to): \(amount) (\(kind))" + (ref.map { ", ref " + $0 } ?? "")
        return CaseAIRecord(kind: .fact, text: text, entityType: CaseAIRecord.moneyType, role: kind, dateText: date, from: from, to: to,
                            relation: amount, quote: quote, document: doc, origin: "picture")
    }

    @Test("FAIR5 harbor: the same statement line recorded twice (two spellings, two refs or the same) is one movement")
    func harbor() throws {
        let bank = UUID(), trust = UUID()
        let records = [
            Self.rec("1400000.00", "Northgate Port Authority", "Deepline Dredging Inc. ****7731", "2026-03-10", ref: "NPA-2026-014/1",
                     quote: "2026-03-10,Incoming wire - NORTHGATE PORT AUTHORITY - NPA-2026-014/1,****4410,,1400000.00,1594030.17", doc: bank),
            Self.rec("1400000.00", "NORTHGATE PORT AUTHORITY", "Deepline Dredging Inc.", "2026-03-10", ref: "NPA-2026-014/1",
                     quote: "2026-03-10,Incoming wire - NORTHGATE PORT AUTHORITY - NPA-2026-014/1,****4410,,1400000.00,1594030.17", doc: bank, kind: "receipt"),
            Self.rec("95,000.00", "Bluewater Marine Consulting LLC ****0092", "Okafor Family Trust First Coastal Bank ****5528", "18 Mar", ref: "Memo: loan",
                     quote: "18 Mar Wire out — OKAFOR FAMILY TRUST — First Coastal Bank ****5528 95,000.00 86,250.00", doc: trust, kind: "transfer"),
            Self.rec("95,000.00", "BLUEWATER MARINE CONSULTING LLC", "OKAFOR FAMILY TRUST", "18 Mar", ref: "First Coastal Bank ****5528, memo loan",
                     quote: "18 Mar Wire out — OKAFOR FAMILY TRUST — First Coastal Bank ****5528 95,000.00", doc: trust, kind: "transfer"),
        ]
        let flows = CaseAIUnderstanding.partyFlows(records)
        let northgate = try #require(flows.first { $0.names.contains("Northgate Port Authority") })
        #expect(northgate.outTotals == ["": 1_400_000], "\(northgate.outTotals)")
        let okafor = try #require(flows.first { $0.names.contains("OKAFOR FAMILY TRUST") })
        #expect(okafor.inTotals == ["": 95_000], "\(okafor.inTotals)")
    }

    @Test("Generated: same line merged in any currency and date style; different line, reference or time stays two")
    func generated() {
        let doc = UUID()
        for (amount, value) in [("EUR 50.000,00", Decimal(50_000)), ("INR 3,00,000", Decimal(300_000)), ("$12,500.00", Decimal(12_500)), ("£7,400", Decimal(7_400))] {
            for date in ["2026-05-01", "01/05/2026", "1 May 2026"] {
                let line = "\(date) Transfer to Beta Holdings \(amount) balance 9,999.00"
                let same = [Self.rec(amount, "Alpha Ltd", "Beta Holdings", date, ref: nil, quote: line, doc: doc),
                            Self.rec(amount, "Alpha Limited", "Beta Holdings", date, ref: nil, quote: "Transfer to Beta Holdings \(amount)", doc: doc, kind: "receipt")]
                let one = CaseAIUnderstanding.partyFlows(same).first { $0.names.contains("Beta Holdings") }
                #expect(one?.inTotals.values.first == value, "\(amount) \(date): \(String(describing: one?.inTotals))")
                // Two lines of one statement (different balances), two references, or two times: two transactions.
                let lines = [Self.rec(amount, "Alpha Ltd", "Beta Holdings", date, ref: nil, quote: line, doc: doc),
                             Self.rec(amount, "Alpha Ltd", "Beta Holdings", date, ref: nil, quote: "\(date) Transfer to Beta Holdings \(amount) balance 1,111.00", doc: doc)]
                let refs = [Self.rec(amount, "Alpha Ltd", "Beta Holdings", date, ref: "TX-1001", quote: "Transfer to Beta Holdings \(amount) TX-1001", doc: doc),
                            Self.rec(amount, "Alpha Ltd", "Beta Holdings", date, ref: "TX-1002", quote: "Transfer to Beta Holdings \(amount) TX-1002", doc: doc)]
                let times = [Self.rec(amount, "Alpha Ltd", "Beta Holdings", date + " 09:15", ref: nil, quote: "09:15 Transfer to Beta Holdings \(amount)", doc: doc),
                             Self.rec(amount, "Alpha Ltd", "Beta Holdings", date + " 16:40", ref: nil, quote: "Transfer to Beta Holdings \(amount)", doc: doc)]
                for (label, set) in [("lines", lines), ("refs", refs), ("times", times)] {
                    let two = CaseAIUnderstanding.partyFlows(set).first { $0.names.contains("Beta Holdings") }
                    #expect(two?.inTotals.values.first == value * 2, "\(label) \(amount) \(date): \(String(describing: two?.inTotals))")
                }
            }
        }
    }

    @Test("Never merged: another amount, another day, other parties — even quoting the same line")
    func negatives() {
        let doc = UUID()
        let line = "2026-05-01 Transfer to Beta Holdings 5,000.00 and fee 50.00"
        let amounts = [Self.rec("5,000.00", "Alpha Ltd", "Beta Holdings", "2026-05-01", ref: nil, quote: line, doc: doc),
                       Self.rec("50.00", "Alpha Ltd", "Beta Holdings", "2026-05-01", ref: nil, quote: line, doc: doc, kind: "fee")]
        #expect(CaseAIUnderstanding.partyFlows(amounts).first { $0.names.contains("Beta Holdings") }?.inTotals == ["": 5_050])
        let days = [Self.rec("5,000.00", "Alpha Ltd", "Beta Holdings", "2026-05-01", ref: nil, quote: line, doc: doc),
                    Self.rec("5,000.00", "Alpha Ltd", "Beta Holdings", "2026-05-09", ref: nil, quote: line, doc: doc)]
        #expect(CaseAIUnderstanding.partyFlows(days).first { $0.names.contains("Beta Holdings") }?.inTotals == ["": 10_000])
        let parties = [Self.rec("5,000.00", "Alpha Ltd", "Beta Holdings", "2026-05-01", ref: nil, quote: line, doc: doc),
                       Self.rec("5,000.00", "Gamma Ltd", "Beta Holdings", "2026-05-01", ref: nil, quote: line, doc: doc)]
        #expect(CaseAIUnderstanding.partyFlows(parties).first { $0.names.contains("Beta Holdings") }?.inTotals == ["": 10_000])
    }
}
