//
//  AccuracyG1Tests.swift
//  KalsmritikoshTests
//
//  Accuracy G1 (FAIR4 §5 item 3, 2026-11-25): "Money by party" counts each transfer once however many documents record it,
//  and never mixes currencies. The records are the fair4 blind reader's own picture money records (requests/hard-vantage and
//  hard-kiln picture-p1 replies), as CaseAgent writes them; the expected kept amounts are the hard-case keys'.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy G1 — money by party, de-duplicated, per currency")
struct AccuracyG1Tests {
    /// One record_money call as CaseAgent files it.
    static func rec(_ kind: String, _ amount: String, _ from: String?, _ to: String?, _ date: String?, _ ref: String?, _ doc: Int,
                    docs: [Int: UUID]) -> CaseAIRecord {
        let text = [from, to].compactMap { $0 }.joined(separator: " → ") + (from == nil && to == nil ? "" : ": ") + amount + " (\(kind))"
            + (ref.map { ", ref " + $0 } ?? "")
        return CaseAIRecord(kind: .fact, text: text, entityType: CaseAIRecord.moneyType, role: kind, dateText: date, from: from, to: to,
                            relation: amount, quote: amount, document: docs[doc], origin: "picture")
    }

    static func ids(_ n: Int) -> [Int: UUID] { Dictionary(uniqueKeysWithValues: (1...n).map { ($0, UUID()) }) }

    /// fair4 hard-vantage picture (documents as the reader numbered them).
    static func vantage(_ d: [Int: UUID]) -> [CaseAIRecord] {
        [
            rec("receipt", "800000.00", "Purchasers apts 1-4", "Hanley & Moore Solicitors client account", "2026-06-10", "VQ-DEP-01..04", 5, docs: d),
            rec("receipt", "800000.00", "Purchasers apts 5-8", "Hanley & Moore Solicitors client account", "2026-06-24", "VQ-DEP-05..08", 5, docs: d),
            rec("receipt", "800000.00", "Purchasers apts 9-12", "Hanley & Moore Solicitors client account", "2026-07-08", "VQ-DEP-09..12", 5, docs: d),
            rec("payment", "600,000.00", "HANLEY & MOORE SOLICITORS CLIENT ACCOUNT", "ARDMORE PROJECT SERVICES LTD", "03/09/2026", "VQ-REL-01", 3, docs: d),
            rec("receipt", "600000.00", "HANLEY MOORE SOLICITORS CLIENT", "ARDMORE PROJECT SERVICES LTD", "2026-09-03", "VQ-REL-01", 2, docs: d),
            rec("transfer", "550000.00", "ARDMORE PROJECT SERVICES LTD", "TIDEWELL HOLDINGS BV", "2026-09-08", "consultancy", 2, docs: d),
            rec("receipt", "€ 550.000,00", "ARDMORE PROJECT SERVICES LTD", "TIDEWELL HOLDINGS B.V.", "08-09-2026", "consultancy", 4, docs: d),
            rec("transfer", "€ 500.000,00", "TIDEWELL HOLDINGS B.V.", "HANLEY & MOORE SOLICITORS CLIENT", "01-10-2026", "VQ-TOP-01", 4, docs: d),
            rec("receipt", "500,000.00", "TIDEWELL HOLDINGS BV", "HANLEY & MOORE SOLICITORS CLIENT ACCOUNT", "02/10/2026", "VQ-TOP-01", 3, docs: d),
            rec("balance", "1,800,000.00", nil, "HANLEY & MOORE SOLICITORS CLIENT ACCOUNT", "30/09/2026", nil, 3, docs: d),
            rec("payment", "EUR 600,000.00", "Hanley & Moore Solicitors client account", "Ardmore Project Services Ltd", "3 September 2026", "VQ-REL-01", 10, docs: d),
            rec("payment", "600000.00", "Hanley & Moore Solicitors client account", "Ardmore Project Services Ltd", "2026-09-03", "VQ-REL-01 site services", 5, docs: d),
            rec("receipt", "500000.00", "Tidewell Holdings BV", "Hanley & Moore Solicitors client account", "2026-10-02", "VQ-TOP-01", 5, docs: d),
            rec("claim", "EUR 200,000", "each Purchaser", "Hanley & Moore Solicitors client account", nil, "booking deposit per purchaser", 8, docs: d),
            rec("allegation", "€2.4 million", "Buyers", "Hanley & Moore", nil, "booking deposits held in escrow (press)", 11, docs: d),
            rec("balance", "2,300,000.00", nil, "HANLEY & MOORE SOLICITORS CLIENT ACCOUNT", "31/10/2026", nil, 3, docs: d),
            rec("balance", "51000.00", nil, "ARDMORE PROJECT SERVICES LTD", "2026-09-30", nil, 2, docs: d),
            rec("balance", "€ 52.500,00", nil, "TIDEWELL HOLDINGS B.V.", "31-10-2026", nil, 4, docs: d),
        ]
    }

    /// fair4 hard-kiln picture.
    static func kiln(_ d: [Int: UUID]) -> [CaseAIRecord] {
        [
            rec("claim", "AUD 2,400,000", "Kiln Street Logistics Pty Ltd", "Southern Cross Mutual Insurance", nil, "SCM-CP-0098812", 5, docs: d),
            rec("receipt", "900000.00", "SOUTHERN CROSS MUTUAL", "KILN STREET LOGISTICS PTY LTD", "30/07/2026", "SCM-CP-0098812 INTERIM", 3, docs: d),
            rec("transfer", "350000.00", "BRADLEY J KERR", "PEMBERTON WHOLESALE PTY LTD", "08/07/2026", "loan", 2, docs: d),
            rec("receipt", "350,000.00", "B KERR", "PEMBERTON WHOLESALE PTY LTD", "08 Jul 26", "loan", 4, docs: d),
            rec("invoice", "350000.00", "Kiln Street Logistics Pty Ltd", "Pemberton Wholesale Pty Ltd", "2026-07-09", "KSL-0907", 11, docs: d),
            rec("receipt", "350000.00", "PEMBERTON WHOLESALE", "Kiln Street Logistics Pty Ltd", "09/07/2026", "KSL-0907", 3, docs: d),
            rec("refund", "350000.00", "Kiln Street Logistics Pty Ltd", "PEMBERTON WHOLESALE", "03/08/2026", "KSL-CN-0907", 3, docs: d),
            rec("payment", "280,000.00", "Pemberton Wholesale Pty Ltd", "B KERR", "06 Aug 26", "director loan repayment", 4, docs: d),
            rec("payment", "350,000.00", "PEMBERTON WHOLESALE PTY LTD", "KILN STREET LOGISTICS", "09 Jul 26", "KSL-0907", 4, docs: d),
            rec("receipt", "350,000.00", "KILN STREET LOGISTICS", "PEMBERTON WHOLESALE PTY LTD", "03 Aug 26", "KSL-CN-0907 refund", 4, docs: d),
            rec("receipt", "280000.00", "PEMBERTON WHOLESALE PTY LTD", "BRADLEY J KERR", "06/08/2026", "director loan repayment", 2, docs: d),
            rec("refund", "-350000.00", "Kiln Street Logistics Pty Ltd", "Pemberton Wholesale Pty Ltd", "2026-08-03", "KSL-CN-0907", 11, docs: d),
            rec("receipt", "900000.00", "Southern Cross Mutual", "Kiln Street Logistics Pty Ltd", "2026-07-30", "SCM-CP-0098812", 11, docs: d),
            rec("estimate", "$900,000", "Southern Cross Mutual Insurance", "Kiln Street Logistics Pty Ltd", nil, "recommended interim payment", 9, docs: d),
            rec("invoice", "AUD 350,000", "Kiln Street Logistics Pty Ltd", "Pemberton Wholesale Pty Ltd", "9 July 2026", "sale price of lots 14 to 39", 10, docs: d),
            rec("receipt", "48200.00", "METRO RETAIL GROUP", "Kiln Street Logistics Pty Ltd", "06/07/2026", "KSL-0902", 3, docs: d),
        ]
    }

    @Test("G1: vantage — Ardmore kept EUR 50,000 and Tidewell kept EUR 50,000 (FAIR4 vantage q1: 700,000 and −400,000)")
    func vantageKept() throws {
        let d = Self.ids(12)
        let flows = CaseAIUnderstanding.partyFlows(Self.vantage(d))
        let ardmore = try #require(flows.first { $0.name.uppercased().hasPrefix("ARDMORE") })
        #expect(ardmore.inTotals == ["EUR": 600_000], "\(ardmore.inTotals)")
        #expect(ardmore.outTotals == ["EUR": 550_000], "\(ardmore.outTotals)")
        #expect(ardmore.keptTotals == ["EUR": 50_000], "\(ardmore.keptTotals)")
        #expect(ardmore.incoming.count == 1 && Set(ardmore.incoming[0].documents) == Set([d[2], d[3], d[5], d[10]].compactMap { $0 }),
                "one €600,000 release recorded in four documents")
        let tidewell = try #require(flows.first { $0.name.uppercased().hasPrefix("TIDEWELL") })
        #expect(tidewell.keptTotals == ["EUR": 50_000], "\(tidewell.keptTotals)")
        #expect(tidewell.outgoing.count == 1, "the 1 Oct debit and the 2 Oct credit of VQ-TOP-01 are one transfer")
        let hanley = try #require(flows.first { $0.name.uppercased().hasPrefix("HANLEY") })
        #expect(hanley.inTotals == ["EUR": 2_900_000], "three deposits of 800,000 + the 500,000 top-up: \(hanley.inTotals)")
        #expect(hanley.outTotals == ["EUR": 600_000])
        let number = Dictionary(uniqueKeysWithValues: d.map { ($0.value, $0.key) })
        let line = CaseAIUnderstanding.flowLine(ardmore, number: number)
        #expect(line.contains("kept (in − out) EUR 600,000 − EUR 550,000 = EUR 50,000"), "\(line)")
        #expect(line.contains("recorded in [D2] [D3] [D5] [D10]"), "\(line)")
        #expect(!line.contains("1,800,000") && !line.contains("700,000"), "no double count: \(line)")
    }

    @Test("G1: kiln — Pemberton kept 70,000 (FAIR4: −210,000); Kerr −70,000; the insurer's 900,000 counted once")
    func kilnKept() throws {
        let d = Self.ids(11)
        let flows = CaseAIUnderstanding.partyFlows(Self.kiln(d))
        let pemberton = try #require(flows.first { $0.name.uppercased().hasPrefix("PEMBERTON") })
        #expect(pemberton.inTotals == ["": 700_000], "\(pemberton.inTotals)")
        #expect(pemberton.outTotals == ["": 630_000], "\(pemberton.outTotals)")
        #expect(pemberton.keptTotals == ["": 70_000], "\(pemberton.keptTotals)")
        let kerr = try #require(flows.first { $0.name.uppercased().contains("KERR") })
        #expect(kerr.names.contains("B KERR") && kerr.names.contains("BRADLEY J KERR"), "an initial matches its word: \(kerr.names)")
        #expect(kerr.keptTotals == ["": -70_000], "\(kerr.keptTotals)")
        let kiln = try #require(flows.first { $0.name.uppercased().hasPrefix("KILN") })
        #expect(kiln.inTotals == ["": 1_298_200], "48,200 + 350,000 + 900,000 once each: \(kiln.inTotals)")
        #expect(kiln.outTotals == ["": 350_000], "the refund recorded three times (once as −350000.00) is one: \(kiln.outTotals)")
    }

    @Test("G1: same document twice is two movements; different currencies never merge or add; the case's one currency is adopted")
    func guards() throws {
        let d = Self.ids(3)
        // Two equal payments on one statement the same day are two payments.
        let twice = [Self.rec("payment", "500.00", "A Co", "B Co", "2026-05-01", nil, 1, docs: d),
                     Self.rec("payment", "500.00", "A Co", "B Co", "2026-05-01", nil, 1, docs: d)]
        let b = try #require(CaseAIUnderstanding.partyFlows(twice).first { $0.name == "B Co" })
        #expect(b.inTotals == ["": 1_000])
        // USD and EUR of the same number are different movements; nothing is adopted when the case names two currencies.
        let mixed = [Self.rec("payment", "USD 500", "A Co", "B Co", "2026-05-01", nil, 1, docs: d),
                     Self.rec("receipt", "EUR 500", "A Co", "B Co", "2026-05-01", nil, 2, docs: d),
                     Self.rec("payment", "70", "B Co", "C Co", "2026-05-02", nil, 3, docs: d)]
        let bm = try #require(CaseAIUnderstanding.partyFlows(mixed).first { $0.name == "B Co" })
        #expect(bm.inTotals == ["USD": 500, "EUR": 500])
        #expect(bm.keptTotals == ["USD": 500, "EUR": 500, "": -70])
        let line = CaseAIUnderstanding.flowLine(bm, number: [:])
        #expect(line.contains("never added together"), "\(line)")
        // A different date and no shared reference: two movements.
        let two = [Self.rec("payment", "EUR 500", "A Co", "B Co", "2026-05-01", "X-1", 1, docs: d),
                   Self.rec("receipt", "EUR 500", "A Co", "B Co", "2026-06-01", "X-2", 2, docs: d)]
        #expect(CaseAIUnderstanding.partyFlows(two).first { $0.name == "B Co" }?.inTotals == ["EUR": 1_000])
    }
}
