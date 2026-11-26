//
//  AccuracyD6Tests.swift
//  KalsmritikoshTests
//
//  Accuracy D6 (FAIR5 §6 item 5, 2026-11-25): a cross-document discrepancy line is never cut before its decisive part (the
//  dates, the day counts, the records' kinds and documents); the money records' descriptions are shortened instead, and
//  the [D<n>] tags stay. FAIR5 harbor q3: "… 2026-03-04 is 6 days befo… [D2]".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy D6 — discrepancy lines keep their key part")
struct AccuracyD6Tests {
    @Test("FAIR5 harbor: with long record descriptions the line keeps both comparisons whole and in the briefing")
    func harborLongDescriptions() throws {
        let h = try AccuracyF4Tests.harbor()
        let long = String(repeating: "NORTHGATE PORT AUTHORITY → Deepline Dredging Inc.: 1400000.00 (payment), ref NPA-2026-014/1 ", count: 3)
        let receipt = CaseAIRecord(kind: .fact, text: long, entityType: CaseAIRecord.moneyType, role: "payment", dateText: "2026-03-10",
                                   from: "Northgate Port Authority", to: "Deepline Dredging Inc.", relation: "1400000.00", quote: "1400000.00",
                                   document: h.ids["harbor-bank-deepline-7731-march.csv"], origin: "picture")
        let lines = CaseLedgerBriefing.discrepancies(texts: h.texts, number: h.number, records: [receipt])
        let bmc = try #require(lines.first { $0.hasPrefix("- BMC-0311:") }, "\(lines)")
        #expect(bmc.contains("2026-03-04 is 6 days before the 2026-03-10 payment"), "\(bmc)")
        #expect(bmc.contains("2026-03-13 is 3 days after the 2026-03-10 payment"), "\(bmc)")
        #expect(bmc.contains("2026-03-04 in [D2]") && bmc.contains("[D1]"), "\(bmc)")
        #expect(bmc.count <= CaseLedgerBriefing.lineLength, "descriptions shortened to fit: \(bmc.count)")
        #expect(!bmc.contains("befo…"))
    }

    @Test("Generated: any number of comparisons and description lengths — never a cut comparison, tags kept")
    func generated() {
        let ids = (1...4).map { _ in UUID() }
        let number = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
        for descLength in [10, 80, 200, 600] {
            let texts = [ids[0]: "2026-04-01 transfer REF-7781 9,500.00", ids[1]: "2026-04-20 ledger REF-7781 9,500.00",
                         ids[2]: "2026-05-15 note on REF-7781 9,500.00", ids[3]: "unrelated"]
            let desc = String(String(repeating: "Alpha Trading Company → Beta Holdings Limited ", count: 20).prefix(descLength))
            let record = CaseAIRecord(kind: .fact, text: desc, entityType: CaseAIRecord.moneyType, role: "payment", dateText: "2026-04-10",
                                      from: "Alpha", to: "Beta", relation: "100.00", quote: "100.00", document: ids[3], origin: "picture")
            let lines = CaseLedgerBriefing.discrepancies(texts: texts, number: number, records: [record])
            guard let l = lines.first(where: { $0.hasPrefix("- REF-7781:") }) else { Issue.record("no line: \(lines)"); continue }
            for (day, rel) in [("2026-04-01", "9 days before"), ("2026-04-20", "10 days after"), ("2026-05-15", "35 days after")] {
                #expect(l.contains("\(day) is \(rel) the 2026-04-10 payment"), "\(descLength): \(l)")
            }
            #expect(l.contains("[D4]"), "\(l)")
            #expect(!l.contains("befo…") && !l.contains("aft…"))
        }
        #expect(CaseLedgerBriefing.shortened("Alpha Trading Company Limited", to: 14) == "Alpha Trading…")
        #expect(CaseLedgerBriefing.shortened("Alpha Trading Company Limited", to: 12) == "Alpha…")
        #expect(CaseLedgerBriefing.shortened("short", to: 40) == "short")
        #expect(CaseLedgerBriefing.shortened("anything", to: 0) == "")
    }
}
