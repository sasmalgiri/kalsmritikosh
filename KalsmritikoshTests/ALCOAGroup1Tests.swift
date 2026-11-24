//
//  ALCOAGroup1Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 1 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-01 re-found AI records come back,
//  ALC-03 locale-aware amounts and unclear currencies, ALC-04 custody events, ALC-05 vault re-hash on open, ALC-06 the
//  audit-chain key survives a restore, ALC-09 "Stopped early", ALC-22 the FAIR2 checker fixes.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 1 — ALC-01/03/04/05/06/09/22", .serialized)
struct ALCOAGroup1Tests {

    // MARK: - ALC-01

    @Test("ALC-01: a record re-found after its document changed comes back as a new row; the withdrawn row stays, history kept")
    func refoundRecordComesBack() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        func fact() -> CaseAIRecord {
            CaseAIRecord(kind: .fact, text: "Kestrel was paid INR 50,000", quote: "debit INR 50,000 to Kestrel", document: doc,
                         origin: "picture", documentFingerprint: "fp1")
        }
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 1)
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 0, "an active repeat is skipped")
        #expect(try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed") == 1)
        #expect(try await repo.records(caseID: f.caseA).isEmpty)
        // Re-found after the change: it is back.
        #expect(try await repo.record(caseID: f.caseA, [fact()]) == 1)
        #expect(try await repo.records(caseID: f.caseA).count == 1)
        let all = try await repo.records(caseID: f.caseA, includeWithdrawn: true)
        #expect(all.count == 2, "the withdrawn version is kept")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_records WHERE withdrawn_at IS NOT NULL AND withdrawn_reason = 'changed';", []) == 1)
        // A second change and re-find: a third row, every earlier one kept.
        try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed again")
        #expect(try await repo.record(caseID: f.caseA, [fact(), fact()]) == 1, "one row per statement within a batch")
        #expect(try await repo.records(caseID: f.caseA, includeWithdrawn: true).count == 3)
        #expect(try await repo.records(caseID: f.caseA).count == 1)
        await f.state.shutdown()
    }

    // MARK: - ALC-03

    @Test("ALC-03: comma-decimal, space, Swiss and Indian grouping, scale words, ISO codes; $ / Rs never assumed")
    func amountsAllStyles() {
        func v(_ s: String) -> Decimal? { CaseAgent.amount(s)?.value }
        #expect(v("€1.234,56") == Decimal(string: "1234.56") && CaseAgent.amount("€1.234,56")?.currency == "EUR")
        #expect(v("EUR 1 234,56") == Decimal(string: "1234.56"))
        #expect(v("CHF 1'234.50") == Decimal(string: "1234.5") && CaseAgent.amount("CHF 1'234.50")?.currency == "CHF")
        #expect(v("₹1,23,456.78") == Decimal(string: "123456.78") && CaseAgent.amount("₹1,23,456.78")?.currency == "INR")
        #expect(v("SEK 1.234.567") == 1_234_567)
        #expect(v("12,50 EUR") == Decimal(string: "12.5"))
        #expect(v("INR 50,000") == 50_000)
        #expect(v("JPY 2.5 billion") == 2_500_000_000 && CaseAgent.amount("JPY 2.5 billion")?.currency == "JPY")
        #expect(v("AUD 3 mio") == 3_000_000)
        #expect(CaseAgent.amounts(in: "all 500 items were counted").isEmpty, "'all' is not Albanian lek")
        #expect(CaseAgent.amounts(in: "INV 500 was raised").isEmpty, "a 3-letter word that is no ISO code names no currency")
        let dollar = CaseAgent.amount("$1,200")
        #expect(dollar?.currency == nil && dollar?.isCurrencyUnclear == true && dollar?.candidates.contains("USD") == true && dollar?.candidates.contains("AUD") == true)
        #expect(CaseAgent.amount("¥5,000")?.candidates == ["JPY", "CNY"])
        #expect(CaseAgent.amount("A$5,000")?.currency == "AUD" && CaseAgent.amount("US$5")?.currency == "USD")
    }

    @Test("ALC-03 sum: an unclear $ is reported, never guessed; the AI's code, the document's code or the other terms' code resolves it; currencies never mix")
    func sumUnclearCurrency() {
        let unclear = CaseAgent.sum(plus: ["$100", "$50"], minus: [])
        #expect(unclear?.text.contains("currency unclear") == true && unclear?.totals["?$"] == 150, "\(unclear?.text ?? "")")
        #expect(unclear?.text.contains("USD") == true, "the candidates are named")
        let byAI = CaseAgent.sum(plus: ["$100", "$50"], minus: [], currency: "AUD")
        #expect(byAI?.totals == ["AUD": 150], "\(byAI?.text ?? "")")
        let byDoc = CaseAgent.sum(plus: ["$100"], minus: [], context: { _ in ["All amounts in this statement are in CAD."] })
        #expect(byDoc?.totals == ["CAD": 100] && byDoc?.text.contains("read as CAD") == true)
        let twoCodes = CaseAgent.sum(plus: ["$100"], minus: [], context: { _ in ["USD and AUD accounts"] })
        #expect(twoCodes?.totals["?$"] == 100, "two possible codes: still unclear")
        let others = CaseAgent.sum(plus: ["USD 100", "$50"], minus: [])
        #expect(others?.totals == ["USD": 150] && others?.text.contains("the currency the other terms name") == true)
        let never = CaseAgent.sum(plus: ["INR 100", "$50"], minus: [])
        #expect(never?.totals.count == 2 && never?.totals["INR"] == 100 && never?.totals["?$"] == 50)
        #expect(never?.text.contains("never added together") == true)
        let eu = CaseAgent.sum(plus: ["€1.234,56", "EUR 765,44"], minus: [])
        #expect(eu?.totals == ["EUR": 2000], "\(eu?.text ?? "")")
    }
}
