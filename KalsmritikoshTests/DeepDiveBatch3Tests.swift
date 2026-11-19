//
//  DeepDiveBatch3Tests.swift
//  KalsmritikoshTests
//
//  Deep dive 2026-11-14 batch 3 (money, dates, CSV, locators) — one regression test per confirmed defect
//  (docs/SMART_MAP_DEFECT_LOG.md, "Deep dive 2026-11-14 batch 3"). Synthetic ledgers on throwaway migrated databases; no
//  model, no network. Every calendar date is built in an explicit zone; where a zone matters the test runs in an
//  east-of-UTC zone (Asia/Kolkata) and a west-of-UTC zone (America/New_York) — CI runs in UTC.
//

import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - Helpers

private let dd3Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private func dd3Source(_ path: String) -> String { (try? String(contentsOf: dd3Root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

private enum DD3 {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
    static let newYork = TimeZone(identifier: "America/New_York") ?? .gmt
    static let utc = TimeZone(identifier: "UTC") ?? .gmt
    static let zones = [kolkata, newYork]

    /// A wall-clock moment in `zone`.
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi)) ?? Date(timeIntervalSince1970: 0)
    }

    static func input(_ kind: CaseMoneyKind, _ amount: String, date: String? = nil, ref: String? = nil, payer: String? = nil, payee: String? = nil,
                      from: UUID? = nil, to: UUID? = nil, currency: String? = "INR") -> CaseMoneyRecordInput {
        var i = CaseMoneyRecordInput(kind: kind, amountText: amount)
        i.date = date; i.reference = ref; i.payerName = payer; i.payeeName = payee; i.payerAccountID = from; i.payeeAccountID = to
        i.currency = currency
        return i
    }

    /// Every line of a CSV text (split on CR and LF scalars) — none may start, past a quote or spaces, with a formula sign.
    static func noLineStartsWithFormula(_ s: String) -> Bool {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\r" || u == "\n" { lines.append(String(line)); line = String.UnicodeScalarView(); continue }
            line.append(u)
        }
        lines.append(String(line))
        return lines.allSatisfy { l in
            let t = l.drop { $0 == "\"" || $0 == " " }
            guard let c = t.first else { return true }
            return !["=", "+", "-", "@", "＝", "＋", "－", "＠"].contains(c)
        }
    }

    /// One quoted cell that an RFC 4180 reader reads back as exactly one cell.
    static func isOneQuotedCell(_ s: String) -> Bool {
        let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
        let body = t.hasSuffix("\r") ? String(t.dropLast()) : t
        guard body.hasPrefix("\""), body.hasSuffix("\""), body.count >= 2 else { return false }
        let grid = WorkbenchCSV.parse(body)
        return grid.count == 1 && grid[0].count == 1
    }
}

@Suite("Deep dive batch 3 — money, dates, CSV, locators", .serialized)
struct DeepDiveBatch3Tests {

    // MARK: 1 — exchange dates at their own precision, in their own zone

    @Test("1: the exchange writes a date at its precision in its recorded zone (else the reader's) and reads it back at that precision")
    func exchangeDatesAtPrecision() async throws {
        for zone in DD3.zones {
            // A zone-less day is that zone's local midnight (addJournal cuts it there): the exported day is that day,
            // never the UTC day before (Kolkata) — the old writer formatted it in UTC.
            let midnight = DD3.at(2026, 3, 5, in: zone)
            #expect(CaseExchange.dateText(midnight, precision: .day, zone: nil, fallback: zone) == "2026-03-05", "\(zone.identifier)")
            #expect(CaseExchange.dateText(midnight, precision: nil, zone: nil, fallback: zone) == "2026-03-05")
            // Minute precision keeps its time and offset; month and year never invent a day.
            let morning = DD3.at(2026, 3, 5, 9, 30, in: zone)
            let minute = CaseExchange.dateText(morning, precision: .minute, zone: zone.identifier, fallback: DD3.utc)
            #expect(minute == (zone == DD3.kolkata ? "2026-03-05T09:30+05:30" : "2026-03-05T09:30-05:00"))
            #expect(CaseExchange.dateText(midnight, precision: .month, zone: nil, fallback: zone) == "2026-03")
            #expect(CaseExchange.dateText(midnight, precision: .year, zone: nil, fallback: zone) == "2026")
            // …and each is read back at the same precision.
            let back = try #require(CaseExchange.placed(minute))
            #expect(back.precision == .minute && back.date == morning)
            #expect(TimeZone(identifier: back.zone)?.secondsFromGMT(for: morning) == zone.secondsFromGMT(for: morning))
        }
        #expect(CaseExchange.placed("2026-03")?.precision == .month)
        #expect(CaseExchange.placed("2026")?.precision == .year)
        #expect(CaseExchange.placed("2026-Q2")?.precision == .quarter)
        #expect(CaseExchange.placed("2026-03-05")?.precision == .day)
        #expect(CaseExchange.placed("2026-03-05")?.date == DD3.at(2026, 3, 5, in: DD3.utc))
        #expect(CaseExchange.placed("2026-02-30") == nil && CaseExchange.placed("5 March 2026") == nil && CaseExchange.placed("१५ मार्च २०२४") == nil)

        // The repository round trip, in both zones.
        for zone in DD3.zones {
            let f = try await CaseFileTests.fixture(title: "Exchange \(zone.identifier)")
            let day = DD3.at(2026, 3, 5, in: zone)
            // Unknown precision is stored as given (not cut): the exported day is the day in the reader's zone.
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Zone-less day", eventDate: day, evidenceRef: nil, actor: "Ada")
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Meeting at 09:30", eventDate: DD3.at(2026, 3, 5, 9, 30, in: zone),
                                            evidenceRef: nil, datePrecision: .minute, timeZoneID: zone.identifier, actor: "Ada")
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Some time in March", eventDate: DD3.at(2026, 3, 1, in: zone),
                                            evidenceRef: nil, datePrecision: .month, timeZoneID: zone.identifier, actor: "Ada")
            let out = try await f.file.exchangeDocument(caseID: f.caseID, sourceSystem: "office-a", timeZone: zone)
            let dates = Dictionary(uniqueKeysWithValues: out.records.map { ($0.text, $0.date ?? "") })
            #expect(dates["Zone-less day"] == "2026-03-05", "\(zone.identifier): \(dates)")
            #expect(dates["Meeting at 09:30"] == (zone == DD3.kolkata ? "2026-03-05T09:30+05:30" : "2026-03-05T09:30-05:00"))
            #expect(dates["Some time in March"] == "2026-03")
            let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Receiving", actor: "Ada", at: Date())
            let r = try await f.file.importExchange(caseID: other.id, data: try CaseExchange.encode(out), actor: "Ada")
            #expect(r.created.count == 3 && !r.limitations.contains { $0.contains("kept as written") }, "\(r)")
            let entries = try await f.file.journal(caseID: other.id, kind: .chronology)
            let meeting = try #require(entries.first { $0.text == "Meeting at 09:30" })
            #expect(meeting.datePrecision == .minute && meeting.eventDate == DD3.at(2026, 3, 5, 9, 30, in: zone))
            let march = try #require(entries.first { $0.text == "Some time in March" })
            #expect(march.datePrecision == .month && march.eventDate == DD3.at(2026, 3, 1, in: DD3.utc))
            let plain = try #require(entries.first { $0.text == "Zone-less day" })
            #expect(plain.datePrecision == .day && plain.eventDate == DD3.at(2026, 3, 5, in: DD3.utc) && plain.dateTimeZone == "UTC")
            let again = try await f.file.exchangeDocument(caseID: other.id, sourceSystem: "office-a", timeZone: zone)
            #expect(Set(again.records.compactMap(\.date)) == Set(out.records.compactMap(\.date)))
            await f.db.close()
        }
    }

    // MARK: 2 — CSV row-break injection

    @Test("2: every CSV writer quotes a cell holding a lone CR or a CRLF as one cell, and no line starts with a formula")
    func csvRowBreaksQuoted() throws {
        let hostile = ["Note\r=cmd|' /C calc'!A0", "note\r\n=HYPERLINK(\"https://x.example\",\"open\")", "\r\n=1+1", "a\n@SUM(A1)"]
        let manifest = ExportManifest(exportedAt: Date(timeIntervalSince1970: 1_772_000_000), appVersion: "test", schemaVersion: 1)
        for h in hostile {
            var outputs: [(String, String)] = [
                ("shared", CSVFormulaGuard.csvField(h)),
                ("map export", CaseMapExportRenderer.csvField(h)),
                ("privilege log", ProductionBuilder.csv(h)),
                ("ledger tables", LedgerExportRenderer.csvField(h)),
                ("workbench", WorkbenchCSV.escape(h)),
                ("case documents", CaseFileDocuments.csv([[h]])),
            ]
            let doc = ExportableDocument(title: "T", table: ExportTable(title: "T", columns: ["c"], rows: [[h]]), manifest: manifest)
            let rendered = WorkProductExporter.render(doc, as: .csv)
            outputs.append(("work product", String(rendered.dropFirst(2))))   // drop the "c\n" header line
            for (name, out) in outputs {
                #expect(DD3.isOneQuotedCell(out), "\(name): \(out.debugDescription)")
                #expect(DD3.noLineStartsWithFormula(out), "\(name): \(out.debugDescription)")
            }
        }
        // A cell starting with CRLF (one Swift Character) is guarded too.
        #expect(CSVFormulaGuard.neutralised("\r\n=1+1").hasPrefix("'"))
        #expect(CSVFormulaGuard.csvField("-50,000.00") == "\"-50,000.00\"", "a plain amount is not altered")
        #expect(CSVFormulaGuard.csvField("plain") == "plain")
        // The writers that live in views route through the one escaper.
        for path in ["Kalsmritikosh/UI/QueryView.swift", "Kalsmritikosh/UI/ConvertView.swift", "Kalsmritikosh/Export/WorkProductExporter.swift"] {
            #expect(dd3Source(path).contains("CSVFormulaGuard.csvField("), "\(path)")
        }
    }

    // MARK: 3 — a shared reference does not merge different days or statement rows

    @Test("3: two instalments under one invoice reference on different days, and two statement rows saying NEFT, are two payments")
    func sharedReferenceDifferentDays() async throws {
        let f = try await CaseFileTests.fixture(title: "Instalments")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 25,000", date: "2026-03-05", ref: "INV-104", payer: "Northwind", payee: "Kestrel"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 25,000", date: "2026-03-12", ref: "INV-104", payer: "Northwind", payee: "Kestrel"), actor: "Ada")
        var o = try #require(try await f.file.moneyLedger(caseID: f.caseID).outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 50_000 && o.grossPaid.transactions == 2, "\(o.grossPaid)")

        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-04-01", periodEnd: "2026-04-30",
                                                    opening: nil, closing: nil, currency: "INR", actor: "Ada")
        _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: """
            Date,Description,Reference,Debit,Credit
            2026-04-02,Payment to Ravi,NEFT,"1,000.00",
            2026-04-02,Payment to Ravi,NEFT,"1,000.00",
            """, actor: "Ada")
        o = try #require(try await f.file.moneyLedger(caseID: f.caseID).outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 52_000 && o.grossPaid.transactions == 4, "\(o.grossPaid)")
        await f.db.close()
    }

    // MARK: 4 — the same payment with its parties written differently

    @Test("4: one reference with the payee written two ways, or no payer, counts once; a person's 'same' joins differently named parties")
    func sameReferenceAcrossPartyNames() async throws {
        let f = try await CaseFileTests.fixture(title: "Kestrel")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 50,000", date: "2026-03-06", ref: "UTR KS-77120", payer: "Northwind", payee: "Kestrel Supplies"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 50,000", date: "2026-03-06", ref: "KS-77120", payer: "Northwind", payee: "Kestrel Supplies Pvt Ltd"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 50,000", date: "2026-03-06", ref: "KS-77120", payee: "Kestrel Supplies"), actor: "Ada")
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        var o = try #require(l.outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 50_000 && o.grossPaid.transactions == 1 && o.grossPaid.records.count == 3, "\(o.grossPaid)")
        #expect(l.transactions().transactions.first?.basis == .reference)

        // No reference, parties named differently: two payments until a person says they are one.
        let a = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 7,000", date: "2026-03-09", payer: "Northwind", payee: "Ravi Kumar"), actor: "Ada")
        let b = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 7,000", date: "2026-03-09", payer: "Northwind Components Ltd", payee: "R. Kumar"), actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        o = try #require(l.outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 64_000)
        _ = try await f.file.decideMoneyIdentity(caseID: f.caseID, recordA: a, recordB: b, decision: .sameTransaction, reason: "One payment, two spellings", actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        o = try #require(l.outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 57_000 && o.grossPaid.transactions == 2, "\(o.grossPaid)")
        #expect(l.transactions().transactions.contains { $0.basis == .decision && Set($0.recordIDs) == [a, b] })
        await f.db.close()
    }

    // MARK: 5 — FAMoney.value separators

    @Test("5: a single separator before three digits is read only when the context decides it; rates take a one-dot decimal")
    func famoneySeparators() async throws {
        let table: [(text: String, currency: String?, rate: Bool, expected: Decimal?)] = [
            ("83.125", nil, true, Decimal(string: "83.125")),
            ("1.500", nil, true, Decimal(string: "1.5")),
            ("83.125", nil, false, nil),
            ("1.500", nil, false, nil),
            ("1,085", nil, false, nil),
            ("1,085", nil, true, nil),
            ("0,125", nil, false, Decimal(string: "0.125")),
            ("0.125", nil, false, Decimal(string: "0.125")),
            ("1,085", "USD", false, 1085),
            ("INR 1,085", nil, false, 1085),
            ("$1,085", nil, false, 1085),
            ("€1.500", nil, false, 1500),
            ("1.500", "EUR", false, 1500),
            ("KWD 1,085", nil, false, Decimal(string: "1.085")),
            ("1.500", "BHD", false, Decimal(string: "1.5")),
            ("1,085", "OMR", false, Decimal(string: "1.085")),
            ("12,34,567", nil, false, 1_234_567),
            ("1,234.56", nil, false, Decimal(string: "1234.56")),
            ("1.234,56", nil, false, Decimal(string: "1234.56")),
            ("1.234.567", nil, false, 1_234_567),
            ("12,5", nil, false, Decimal(string: "12.5")),
            ("(1,000.00)", nil, false, -1000),
            ("INR 50,000", nil, false, 50_000),
            ("12.50", nil, false, Decimal(string: "12.5")),
        ]
        for row in table {
            #expect(FAMoney.value(of: row.text, currency: row.currency, rate: row.rate) == row.expected, "\(row.text) \(row.currency ?? "-") rate:\(row.rate)")
        }
        #expect(FAMoney.read("2.5 lakh")?.value == 250_000)
        #expect(FAMoney.read("1,085") == nil, "ambiguous is not read, never guessed")
        // A rate with three decimals is recorded (it was refused as badRate).
        let f = try await CaseFileTests.fixture(title: "Rates")
        _ = try await f.file.recordConversionRate(caseID: f.caseID, from: "USD", to: "INR", rate: "83.125", rateDate: "2026-03-05", rateSource: "RBI", method: "reference rate", actor: "Ada")
        let l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.conversions.first?.rate == Decimal(string: "83.125"))
        // A stated two-decimal currency reads a group; the record keeps its value.
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "1,085", date: "2026-03-05", payee: "X", currency: "INR"), actor: "Ada")
        #expect(try await f.file.moneyLedger(caseID: f.caseID).records.first?.amount == 1085)
        await f.db.close()
    }

    // MARK: 6 — strict yyyy-MM-dd

    @Test("6: a money day must be exactly yyyy-MM-dd and a calendar day; 2026-3-5 and 26-03-05 are refused")
    func strictMoneyDays() async throws {
        #expect(CaseMoneyLedger.date("2026-03-05") != nil)
        for bad in ["2026-3-5", "26-03-05", "2026-02-30", "2026-03-05 ", "２０２６-03-05"] { #expect(CaseMoneyLedger.date(bad) == nil, "\(bad)") }
        let f = try await CaseFileTests.fixture(title: "Days")
        await #expect(throws: (any Error).self) {
            _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 10", date: "2026-3-5", payee: "X"), actor: "Ada")
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 10", date: "26-03-05", payee: "X"), actor: "Ada")
        }
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "1", actor: "Ada")
        await #expect(throws: CaseMoneyError.badPeriod) {
            _ = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-3-1", periodEnd: "2026-03-31", opening: nil, closing: nil, currency: "INR", actor: "Ada")
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.file.recordConversionRate(caseID: f.caseID, from: "USD", to: "INR", rate: "83.10", rateDate: "26-03-05", rateSource: "RBI", method: "m", actor: "Ada")
        }
        #expect(try await f.file.moneyLedger(caseID: f.caseID).records.isEmpty)
        await f.db.close()
    }

    // MARK: 7 — money days and timeline buckets in both zones

    @Test("7: a money node's day is its UTC day everywhere, and the timeline buckets each record in the zone its label uses")
    func moneyDayAndBuckets() async throws {
        let f = try await CaseFileTests.fixture(title: "Timeline")
        let m = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 10", date: "2026-03-05", payee: "X"), actor: "Ada")
        var entries: [TimeZone: UUID] = [:]
        for zone in DD3.zones {
            // 00:30 local on 5 March: the UTC day is 4 March in Kolkata.
            entries[zone] = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Call \(zone.identifier)", eventDate: DD3.at(2026, 3, 5, 0, 30, in: zone),
                                                        evidenceRef: nil, datePrecision: .minute, actor: "Ada")
        }
        let p = try #require(await caseMapLoad(f).projection)
        let mid = CaseMapNodeID(caseID: f.caseID, kind: .moneyRecord, id: m)
        let node = try #require(p.node(mid))
        #expect(node.dateTimeZone == "UTC")
        for zone in DD3.zones {
            #expect(node.timeValue?.label(assuming: zone).contains("5 Mar 2026") == true, "\(zone.identifier): \(node.timeValue?.label(assuming: zone) ?? "")")
            let money = CaseMapDistribution.byDate([mid], in: p, grain: .day, timeZone: zone)
            #expect(money.buckets.map(\.id) == ["date:2026-03-05"], "\(zone.identifier)")
            let jid = CaseMapNodeID(caseID: f.caseID, kind: .journal, recordID: try #require(entries[zone]).uuidString.lowercased())
            let chron = CaseMapDistribution.byDate([jid], in: p, grain: .day, timeZone: zone)
            #expect(chron.buckets.map(\.id) == ["date:2026-03-05"], "\(zone.identifier): \(chron.buckets.map(\.id))")
        }
        await f.db.close()
    }

    // MARK: 8 — same-day and undated onward hops

    @Test("8: a payment by a party that received money the same day, or on an unknown day, is a flagged possible onward hop, not new gross")
    func possibleOnwardHops() async throws {
        let f = try await CaseFileTests.fixture(title: "Hops")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 100", date: "2026-03-05", ref: "A1", payer: "Acme", payee: "Bilal"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 100", date: "2026-03-05", ref: "B1", payer: "Bilal", payee: "Chen"), actor: "Ada")
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        var (by, warnings) = l.outcomes()
        var o = try #require(by["INR"])
        #expect(o.grossPaid.amount == 100 && o.onward.amount == 100 && o.possibleOnward.amount == 100, "\(o)")
        #expect(warnings.contains { $0.contains("possible onward hops") })
        // An undated receipt: also only possibly before.
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 40", ref: "C1", payer: "Dana", payee: "Eli"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 40", date: "2026-03-07", ref: "D1", payer: "Eli", payee: "Farah"), actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        (by, warnings) = l.outcomes()
        o = try #require(by["INR"])
        #expect(o.grossPaid.amount == 140 && o.possibleOnward.amount == 140, "\(o)")
        // Received strictly earlier: an onward hop, not flagged as possible.
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 9", date: "2026-03-01", ref: "E1", payer: "Gita", payee: "Hari"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, DD3.input(.payment, "INR 9", date: "2026-03-02", ref: "F1", payer: "Hari", payee: "Ines"), actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        o = try #require(l.outcomes().byCurrency["INR"])
        #expect(o.grossPaid.amount == 149 && o.onward.amount == 149 && o.possibleOnward.amount == 140)
        await f.db.close()
    }

    // MARK: 9 — statement import

    @Test("9: statements: CRLF files, zero or dash in the unused column, both columns, balance rows, missing dates, quoted CSV, one savepoint")
    func statementImport() async throws {
        let f = try await CaseFileTests.fixture(title: "Statements")
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "2210", actor: "Ada")
        func statement() async throws -> UUID {
            try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-01-01", periodEnd: "2026-01-31", opening: nil, closing: nil, currency: "EUR", actor: "Ada")
        }
        // CRLF: every row is read (it was 0 rows, reported as success).
        let crlf = "Date,Description,Debit,Credit\r\n2026-01-05,Payment to Hans,100.00,0.00\r\n2026-01-06,Refund from Hans,0.00,20.00\r\n2026-01-07,Receipt from Ana,-,30.00\r\n"
        #expect(CaseMoneyStatementParser.rows(crlf).count == 3)
        let st1 = try await statement()
        let before = try await f.db.query("SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = 'moneyRecorded';", [.uuid(f.caseID)]).first?.int(0) ?? -1
        let ids = try await f.file.importStatementRows(caseID: f.caseID, statementID: st1, text: crlf, actor: "Ada")
        #expect(ids.count == 3)
        let after = try await f.db.query("SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = 'moneyRecorded';", [.uuid(f.caseID)]).first?.int(0) ?? -1
        #expect(after - before == 1, "every row in ONE savepoint (one action)")
        let l = try await f.file.moneyLedger(caseID: f.caseID)
        let rows = l.records.filter { ids.contains($0.id) }.sorted { ($0.statementRow ?? 0) < ($1.statementRow ?? 0) }
        #expect(rows.map(\.kind) == [.payment, .refund, .receipt], "a zero or a dash in the unused column is no amount")
        #expect(rows.map(\.amount) == [100, 20, 30])
        // Refused whole, nothing written: both columns, a balance row, a row with no date.
        for bad in ["Date,Description,Debit,Credit\n2026-01-08,Mixed,10.00,20.00",
                    "Date,Description,Debit,Credit\n2026-01-01,Opening balance,,1000.00\n2026-01-09,Payment,5.00,",
                    "Date,Description,Debit,Credit\n2026-01-31,Total,500.00,",
                    "Date,Description,Debit,Credit\n,Payment,5.00,"] {
            let st = try await statement()
            let n = try await f.file.moneyLedger(caseID: f.caseID).records.count
            await #expect(throws: CaseMoneyError.self, "\(bad)") {
                _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: bad, actor: "Ada")
            }
            #expect(try await f.file.moneyLedger(caseID: f.caseID).records.count == n)
        }
        // Quoted CSV: a comma inside a quoted description or amount is one cell (it was split and refused).
        let st2 = try await statement()
        let quoted = try await f.file.importStatementRows(caseID: f.caseID, statementID: st2, text: """
            Date,Description,Debit,Credit
            2026-01-10,"Payment to Hans, Berlin","1,000.00",
            """, actor: "Ada")
        let q = try #require(try await f.file.moneyLedger(caseID: f.caseID).records.first { quoted.contains($0.id) })
        #expect(q.amount == 1000 && q.description?.contains("Hans, Berlin") == true)
        await f.db.close()
    }

    // MARK: 10 — numeric day/month dates

    @Test("10: 05/03/2026 is neither support nor contradiction; ISO and written-month dates still are")
    func ambiguousNumericDates() {
        #expect(StudioEvidenceResolver.isAmbiguousNumericDate("05/03/2026"))
        #expect(!StudioEvidenceResolver.isAmbiguousNumericDate("05/05/2026"), "either way round it is the same day")
        #expect(!StudioEvidenceResolver.isAmbiguousNumericDate("25/03/2026") && !StudioEvidenceResolver.isAmbiguousNumericDate("2026-03-05"))
        // The detector read 05/03/2026 as 3 May (US month/day): it supported a 3 May field. Not any more.
        #expect(StudioEvidenceResolver.supports("2026-05-03", kind: .date, quote: "Paid on 05/03/2026.") != nil)
        #expect(StudioEvidenceResolver.wholeDate("05/03/2026") == nil)
        #expect(StudioEvidenceResolver.supports("2026-03-05", kind: .date, quote: "Paid on 5 March 2026.") == nil)
        #expect(StudioEvidenceResolver.supports("2026-03-05", kind: .date, quote: "Paid on 2026-03-05.") == nil)
        // A statement with an ambiguous date is not checked on it (no failure, and it is not counted as support).
        let c = CaseStatementSupport.check(statement: "Paid on 05/03/2026.", against: "The payment was made on 3 May 2026.")
        #expect(!c.checked.contains { $0.contains("05/03/2026") } && !c.failures.contains { $0.contains("05/03/2026") }, "\(c)")
        let written = CaseStatementSupport.check(statement: "Paid on 4 March 2026.", against: "The payment was made on 3 May 2026.")
        #expect(written.failures.contains { $0.contains("4 March 2026") })
    }

    // MARK: 11 — xls cells for citations

    @Test("11: an .xls row carries its cells by column, empties kept, as XLSX and ODS do — so a cited column can be shown")
    func xlsRowCells() async throws {
        #expect(XlsStructuralParser.cellsByColumn([0: "a", 2: " c "]) == ["a", "", "c"])
        #expect(XlsStructuralParser.cellsByColumn([:]).isEmpty)
        let data = try Data(contentsOf: dd3Root.appendingPathComponent("KalsmritikoshTests/Fixtures/LegacyOffice/sample.xls"))
        let doc = try await XlsStructuralParser().parse(data: data, filename: "sample.xls", type: .xls, logicalSourceID: UUID(), sourceVersionID: UUID())
        let rows = doc.blocks.filter { $0.kind == .spreadsheetRow }
        #expect(!rows.isEmpty)
        for b in rows {
            guard case .array(let xs)? = b.attributes["cells"]?.value else { Issue.record("row \(b.locator.row ?? -1) has no cells"); continue }
            let cells = xs.map { if case .string(let s) = $0 { return s }; return "" }
            #expect(cells.filter { !$0.isEmpty }.joined(separator: "\t") == b.rawText, "the cells are the row's text, at their columns")
        }
    }

    // MARK: 12 — ODS row numbers after repeated rows

    @Test("12: ODS row numbers count a run of repeated empty rows in full (as LibreOffice numbers them) without materialising it")
    func odsRowNumbers() async throws {
        let body = """
        <table:table-row><table:table-cell><text:p>Header</text:p></table:table-cell></table:table-row>\
        <table:table-row table:number-rows-repeated="1000000"><table:table-cell/></table:table-row>\
        <table:table-row><table:table-cell><text:p>After</text:p></table:table-cell></table:table-row>
        """
        let rows = ODSStructuralParser.indexedRows(body)
        #expect(rows.count == 3, "one copy of the empty run is kept")
        #expect(rows.map(\.index) == [0, 1, 1_000_001])
        #expect(rows.last?.cells == ["After"])
        #expect(ODSStructuralParser.rows(body).count == 3)
        let xml = "<office:spreadsheet><table:table table:name=\"Data\">\(body)</table:table></office:spreadsheet>"
        let sheet = try #require(ODSStructuralParser.sheets(xml).first)
        #expect(sheet.indices == [0, 1, 1_000_001])
    }

    // MARK: 13 — ownership periods compared as days

    @Test("13: an ownership period recorded with a time of day holds on its first and last day (days compared as UTC days)")
    func ownershipDays() {
        let from = DD3.at(2026, 3, 5, 10, 0, in: DD3.utc), to = DD3.at(2026, 3, 9, 8, 0, in: DD3.utc)
        let o = CaseMoneyOwnership(id: UUID(), accountID: UUID(), holderPersonID: nil, holderName: "Arjun", relation: .holder, share: nil, via: nil,
                                   validFrom: from, validTo: to, validText: nil, basis: .investigatorNote, sourceVersionID: nil, quote: nil,
                                   suppliedBy: nil, recordedBy: "Ada", recordedAt: from, withdrawnAt: nil)
        #expect(o.holds(onDay: "2026-03-05") == true && o.holds(onDay: "2026-03-09") == true)
        #expect(o.holds(on: DD3.at(2026, 3, 5, in: DD3.utc)) == true, "the money day (UTC midnight) is inside")
        #expect(o.holds(onDay: "2026-03-04") == false && o.holds(onDay: "2026-03-10") == false)
        // Day arithmetic is in UTC (it was this Mac's zone, which moved a day across a daylight-saving change).
        #expect(CaseMoneyLedger.monthBounds("2026-03") == ("2026-03-01", "2026-03-31"))
        #expect(CaseMoneyLedger.monthBounds("2026-11") == ("2026-11-01", "2026-11-30"))
    }
}
