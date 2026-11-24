//
//  AccuracyF4Tests.swift
//  KalsmritikoshTests
//
//  Accuracy F4 (FAIR3 root cause, 2026-11-25): the briefing's "Cross-document discrepancies" — the same reference written
//  with different dates (or the same date with different amounts) across documents, with where each date falls next to the
//  nearest dated money record. Exact matching only; never a conclusion.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy F4 — cross-document discrepancies")
struct AccuracyF4Tests {
    static let harborDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AgentEvalHard/hard-harbor")

    static func harbor() throws -> (texts: [UUID: String], number: [UUID: Int], ids: [String: UUID]) {
        let names = ["harbor-bank-deepline-7731-march.csv", "harbor-deepline-general-ledger.csv", "harbor-bank-bluewater-0092-march.txt",
                     "harbor-invoice-BMC-0311.txt", "harbor-email-marsh-to-voss.eml"]
        var texts: [UUID: String] = [:], number: [UUID: Int] = [:], ids: [String: UUID] = [:]
        for (i, n) in names.enumerated() {
            let id = UUID()
            texts[id] = try String(contentsOf: harborDir.appendingPathComponent(n), encoding: .utf8)
            number[id] = i + 1; ids[n] = id
        }
        return (texts, number, ids)
    }

    @Test("F4: harbor's BMC-0311 — ledger 2026-03-04 vs both banks 13 Mar, the ledger date before the 10 Mar instalment")
    func harborReference() throws {
        let h = try Self.harbor()
        let receipt = CaseAIRecord(kind: .fact, text: "Northgate Port Authority → Deepline Dredging Inc. (****7731): 1400000.00 (receipt)",
                                   entityType: CaseAIRecord.moneyType, role: "receipt", dateText: "2026-03-10", from: "Northgate Port Authority",
                                   to: "Deepline Dredging Inc. (****7731)", relation: "1400000.00", quote: "1400000.00",
                                   document: h.ids["harbor-bank-deepline-7731-march.csv"], origin: "picture")
        let paid = CaseAIRecord(kind: .fact, text: "Deepline Dredging Inc. → Bluewater Marine Consulting LLC (****0092): 180,000.00 (payment), ref BMC-0311",
                                entityType: CaseAIRecord.moneyType, role: "payment", dateText: "13 Mar", relation: "180,000.00", quote: "BMC-0311 180,000.00",
                                document: h.ids["harbor-bank-bluewater-0092-march.txt"], origin: "picture")
        let lines = CaseLedgerBriefing.discrepancies(texts: h.texts, number: h.number, records: [receipt, paid])
        let bmc = try #require(lines.first { $0.hasPrefix("- BMC-0311:") }, "\(lines)")
        #expect(bmc.contains("2026-03-04 in [D2]"), "\(bmc)")
        #expect(bmc.contains("2026-03-13 in [D1] [D3]"), "\(bmc)")
        #expect(bmc.contains("2026-03-04 is 6 days before the 2026-03-10 receipt"), "\(bmc)")
        #expect(bmc.contains("2026-03-13 is 3 days after the 2026-03-10 receipt"), "the key's own payment record is not its own yardstick: \(bmc)")
        #expect(!bmc.lowercased().contains("fraud") && !bmc.lowercased().contains("backdat"), "never a conclusion")
        // Stable: the same input gives the same lines.
        #expect(CaseLedgerBriefing.discrepancies(texts: h.texts, number: h.number, records: [receipt, paid]) == lines)
    }

    @Test("F4: same reference + same date + different amounts is listed; one document's own dates, and agreeing documents, are not")
    func amountsAndAgreement() {
        let a = UUID(), b = UUID(), c = UUID()
        let number = [a: 1, b: 2, c: 3]
        let texts = [a: "2026-05-01 Invoice INV-77 total 5,000.00", b: "1 May 2026 paid INV-77 4,500.00", c: "Nothing dated here about INV-77."]
        let lines = CaseLedgerBriefing.discrepancies(texts: texts, number: number, records: [])
        #expect(lines == ["- INV-77: same date (2026-05-01), different amounts — 5,000 in [D1]; 4,500 in [D2]"], "\(lines)")
        let agree = [a: "2026-05-01 Invoice INV-77 total 5,000.00", b: "1 May 2026 paid INV-77 5,000.00"]
        #expect(CaseLedgerBriefing.discrepancies(texts: agree, number: number, records: []).isEmpty)
        let oneDoc = [a: "2026-05-01 INV-77 ordered\n2026-05-09 INV-77 delivered", b: "unrelated"]
        #expect(CaseLedgerBriefing.discrepancies(texts: oneDoc, number: number, records: []).isEmpty)
    }

    @Test("F4: the briefing carries the section from the documents' texts; without texts there is none")
    func briefingSection() throws {
        let h = try Self.harbor()
        var m = CaseLedgerBriefing.Material()
        m.aiRecords = [CaseAIRecord(kind: .entity, text: "Bluewater Marine Consulting LLC", entityType: "organisation", quote: "Bluewater",
                                    document: h.ids["harbor-invoice-BMC-0311.txt"], origin: "picture")]
        m.documentTexts = h.texts
        let b = CaseLedgerBriefing.build(m, number: h.number)
        #expect(b.text.contains("## " + CaseLedgerBriefing.discrepancyTitle))
        #expect(b.text.contains("- BMC-0311: different dates across documents"))
        m.documentTexts = [:]
        #expect(!CaseLedgerBriefing.build(m, number: h.number).text.contains(CaseLedgerBriefing.discrepancyTitle))
    }
}
