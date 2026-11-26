//
//  AccuracyG2Tests.swift
//  KalsmritikoshTests
//
//  Accuracy G2 (FAIR4 §5 item 4, 2026-11-25): dates are read in each document's own day/month order; an ambiguous date is
//  compared under both readings; a discrepancy is listed only when two documents share no date for the key. The five false
//  FAIR4 flags (kiln KSL-0907 and KSL-CN-0907, vantage 500,000 / 600,000, inv104 account …8804) must not appear; harbor's
//  genuine BMC-0311 must.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Accuracy G2 — document date order in cross-document discrepancies")
struct AccuracyG2Tests {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func load(_ dir: URL) throws -> (texts: [UUID: String], number: [UUID: Int]) {
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") }.sorted()
        var texts: [UUID: String] = [:], number: [UUID: Int] = [:]
        for (i, f) in files.enumerated() {
            let id = UUID()
            texts[id] = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            number[id] = i + 1
        }
        return (texts, number)
    }

    static func lines(_ dir: URL) throws -> [String] {
        let c = try load(dir)
        return CaseLedgerBriefing.discrepancies(texts: c.texts, number: c.number, records: [])
    }

    @Test("G2: each document's order — day over 12, day-month words, non-US currency → day-first; month over 12 or US → month-first")
    func order() {
        #expect(DateOrder.dayFirst("30/07/2026 credit\n09/07/2026 credit") == true)
        #expect(DateOrder.dayFirst("08 Jul 26 Deposit") == true)
        #expect(DateOrder.dayFirst("Balance (EUR) 03/09/2026") == true)
        #expect(DateOrder.dayFirst("09/30/2026 wire\n09/07/2026 wire") == false)
        #expect(DateOrder.dayFirst("On March 13, 2026 the court …") == false)
        #expect(DateOrder.dayFirst("USD 5,000 on 03/09/2026") == false)
        #expect(DateOrder.dayFirst("03/09/2026 paid") == nil)
        let d = VerifiedAnswerComposer.values(in: "03/09/2026").dates[0]
        #expect(DateOrder.show(DateOrder.resolved(d, dayFirst: true)) == "2026-09-03")
        #expect(DateOrder.show(DateOrder.resolved(d, dayFirst: false)) == "2026-03-09")
        #expect(DateOrder.show(d) == "2026-03-09 or 2026-09-03", "unknown order: both readings")
    }

    @Test("G2: the five false FAIR4 flags are gone; harbor's BMC-0311 stays")
    func fair4Flags() throws {
        let hard = Self.tests.appendingPathComponent("Fixtures/AgentEvalHard")
        let kiln = try Self.lines(hard.appendingPathComponent("hard-kiln"))
        #expect(!kiln.contains { $0.hasPrefix("- KSL-0907:") }, "\(kiln)")
        #expect(!kiln.contains { $0.hasPrefix("- KSL-CN-0907:") }, "\(kiln)")
        let vantage = try Self.lines(hard.appendingPathComponent("hard-vantage"))
        #expect(!vantage.contains { $0.contains("500,000 with") || $0.contains("600,000 with") }, "\(vantage)")
        #expect(!vantage.contains { $0.contains("2026-02-10") || $0.contains("2026-01-10") || $0.contains("2026-03-09") }, "\(vantage)")
        let inv104 = try Self.lines(Self.tests.deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/Resources/Fixtures/AcceptanceSupplierINV104"))
        #expect(!inv104.contains { $0.contains("8804") }, "three transfers on one account are not one discrepancy: \(inv104)")
        let harbor = try Self.lines(hard.appendingPathComponent("hard-harbor"))
        let bmc = try #require(harbor.first { $0.hasPrefix("- BMC-0311:") }, "\(harbor)")
        #expect(bmc.contains("2026-03-04") && bmc.contains("2026-03-13"), "\(bmc)")
    }

    @Test("G2: an ambiguous date is flagged only when neither reading matches")
    func ambiguous() {
        let a = UUID(), b = UUID(), c = UUID()
        let number = [a: 1, b: 2, c: 3]
        // Unknown order in both: 03/09 vs 09/03 agree under the swapped reading.
        let agree = [a: "03/09/2026 paid REF-77 100.00", b: "09/03/2026 received REF-77 100.00"]
        #expect(CaseLedgerBriefing.discrepancies(texts: agree, number: number, records: []).isEmpty)
        // Known day-first (a day over 12 elsewhere): 03/09 = 3 Sept, against 2026-03-28 — neither reading matches.
        let differ = [a: "30/08/2026 opening\n03/09/2026 paid REF-77 100.00", c: "2026-03-28 REF-77 invoice 100.00"]
        let lines = CaseLedgerBriefing.discrepancies(texts: differ, number: number, records: [])
        #expect(lines.contains { $0.hasPrefix("- REF-77:") && $0.contains("2026-09-03") && $0.contains("2026-03-28") }, "\(lines)")
    }
}
