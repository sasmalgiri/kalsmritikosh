//
//  SmartMapS7Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S7 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: MONEY and HISTORY of milestone M2; schema v183).
//  Throwaway ledgers; expected values written by hand — the INV-104 money figures come from the fixture's hand-written answer
//  key (Resources/Fixtures/AcceptanceSupplierINV104/inv104-expected-results.json), never from what the code produced. AI off:
//  nothing here calls a model or the network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private enum S7 {
    static var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(SupplierINV104Fixture.folderName)", isDirectory: true)
    }
    static func text(_ name: String) throws -> String { try String(contentsOf: fixtureFolder.appendingPathComponent(name), encoding: .utf8) }
    static func key() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureFolder.appendingPathComponent(SupplierINV104Fixture.expectedName))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    static func count(_ db: Database, _ sql: String, _ binds: [SQLValue]) async throws -> Int { Int(try await db.query(sql, binds).first?.int(0) ?? -1) }
    static func dec(_ s: String?) -> Decimal? { s.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
    static func input(_ kind: CaseMoneyKind, _ amount: String, date: String? = nil, ref: String? = nil, from: UUID? = nil, to: UUID? = nil,
                      payer: String? = nil, payee: String? = nil, currency: String? = nil, source: UUID? = nil, settles: UUID? = nil) -> CaseMoneyRecordInput {
        var i = CaseMoneyRecordInput(kind: kind, amountText: amount)
        i.date = date; i.reference = ref; i.payerAccountID = from; i.payeeAccountID = to; i.payerName = payer; i.payeeName = payee
        i.currency = currency; i.sourceVersionID = source; i.settlesRecordID = settles
        return i
    }
}

// MARK: - MONEY

@MainActor
@Suite("Smart map S7 — money inside the case (MONEY)", .serialized)
struct SmartMapS7MoneyTests {

    @Test("INV-104 through the canonical money records: gross 100,000 / returned 50,000 / net 50,000 (answer key); statement copies and the report count once; the same figures on the map, the report and the forensic schedule")
    func inv104AcrossSurfaces() async throws {
        let key = try S7.key()
        let money = try #require(key["money"] as? [String: Any])
        let cur = try #require(money["currency"] as? String)
        let f = try await CaseFileTests.fixture(title: "Was Kestrel Supplies paid twice for invoice INV-104?")
        func seed(_ name: String, as label: String? = nil) async throws -> UUID {
            try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: label ?? name, text: try S7.text(name)).version
        }
        let stmtText = try S7.text(SupplierINV104Fixture.bankStatement)
        let vStmt = try await seed(SupplierINV104Fixture.bankStatement)
        let vCopy = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: SupplierINV104Fixture.bankCopy, text: stmtText + " ").version
        let vInvoice = try await seed("inv104-invoice.md"), vReport = try await seed("inv104-forensic-report-FR-12.md")
        let vOwner = try await seed("inv104-account-ownership-8804.md")

        // Accounts, their holders and the signatory (sourced). The signatory is a person of the case.
        let a3391 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", institution: "Western Coast Bank", currency: "INR", sourceVersionID: vStmt, actor: "Priya Nair")
        let a8804 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8804", institution: "Western Coast Bank", currency: "INR", sourceVersionID: vOwner, actor: "Priya Nair")
        await #expect(throws: CaseMoneyError.self) { _ = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "A/c 8804", institution: "Western Coast Bank", actor: "Priya Nair") }
        let arjun = try await f.file.addPerson(caseID: f.caseID, name: "Arjun Mehta", role: .other, entityID: nil, contact: nil, notes: nil, actor: "Priya Nair")
        try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a3391, holderName: "Northwind Components Ltd", relation: .holder, basis: .source,
                                               sourceVersionID: vStmt, quote: "Account holder: Northwind Components Ltd", actor: "Priya Nair")
        try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a8804, holderName: "Kestrel Supplies Pvt Ltd", relation: .holder, basis: .source,
                                               sourceVersionID: vOwner, quote: "Account holder: Kestrel Supplies Pvt Ltd", actor: "Priya Nair")
        try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a8804, holderPersonID: arjun, holderName: "Arjun Mehta", relation: .signatory, basis: .source,
                                               sourceVersionID: vOwner, quote: "Authorised signatory: Arjun Mehta, director", actor: "Priya Nair")

        // The statement and its byte-identical copy (two statement records of one account and period), rows imported by the parser.
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: a3391, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: nil, closing: nil,
                                                    currency: "INR", sourceVersionID: vStmt, sourceName: SupplierINV104Fixture.bankStatement, actor: "Priya Nair")
        let stCopy = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: a3391, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: nil, closing: nil,
                                                        currency: "INR", sourceVersionID: vCopy, sourceName: SupplierINV104Fixture.bankCopy, actor: "Priya Nair")
        let rows = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: stmtText, actor: "Priya Nair")
        let copyRows = try await f.file.importStatementRows(caseID: f.caseID, statementID: stCopy, text: stmtText, actor: "Priya Nair")
        let lines = try #require(key["bank_lines"] as? [[String: Any]])
        #expect(rows.count == lines.count && copyRows.count == lines.count)

        // The invoice (not a movement), and the report's three findings recorded as money records of the report.
        let inv = try await f.file.recordMoney(caseID: f.caseID, S7.input(.invoice, "INR 50,000", date: "2026-03-04", ref: "INV-104", to: a8804, source: vInvoice), actor: "Priya Nair")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "INR 50,000", ref: "KS-77120", from: a3391, to: a8804, source: vReport, settles: inv), actor: "Priya Nair")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "INR 50,000", ref: "KS-77985", from: a3391, to: a8804, source: vReport), actor: "Priya Nair")
        let reportCredit = try await f.file.recordMoney(caseID: f.caseID, S7.input(.refund, "INR 50,000", date: "2026-03-19", from: a8804, to: a3391, source: vReport), actor: "Priya Nair")

        var l = try await f.file.moneyLedger(caseID: f.caseID)
        let imported = l.records.filter { rows.contains($0.id) }.sorted { ($0.statementRow ?? 0) < ($1.statementRow ?? 0) }
        #expect(imported.map(\.date) == lines.map { $0["date"] as? String })
        #expect(imported.map(\.kind.rawValue) == lines.compactMap { $0["kind"] as? String }, "debit → payment, the 'Refund from …' credit → refund")
        #expect(imported.allSatisfy { $0.payeeAccountID == a8804 || $0.payerAccountID == a8804 }, "a/c 8804 in the description links the recorded account")
        #expect(imported.map { $0.amount } == lines.map { S7.dec($0["amount"] as? String) })

        // The report's credit has no reference: it may be the statement's refund — a candidate, counted once, flagged.
        var (txs, candidates) = l.transactions()
        #expect(txs.count == 3 && candidates.count >= 1)
        var o = try #require(l.outcomes().byCurrency[cur])
        #expect(o.ifCandidatesSeparate == 50_000, "if they were separate refunds, the returned figure would be low by 50,000")
        // Confirm it (MONEY-04): the candidate is settled by a person's decision; nothing else changes.
        let refundRow = try #require(imported.first { $0.kind == .refund })
        try await f.file.decideMoneyIdentity(caseID: f.caseID, recordA: refundRow.id, recordB: reportCredit, decision: .sameTransaction,
                                             reason: "Same day, amount and accounts as statement row 3", actor: "Priya Nair")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        (txs, candidates) = l.transactions()
        o = try #require(l.outcomes().byCurrency[cur])
        #expect(candidates.isEmpty && o.ifCandidatesSeparate == 0)
        #expect(o.grossPaid.amount == S7.dec(money["gross_paid"] as? String) && o.returned.amount == S7.dec(money["returned"] as? String)
                && o.netOutflow == S7.dec(money["net_outflow"] as? String), "\(o)")
        #expect(o.grossPaid.transactions == money["distinct_settlements"] as? Int, "two equal settlements with their own references stay two")
        let copyCounted = txs.filter { t in t.records.contains { copyRows.contains($0.id) } && t.records.count > 1 }.count
        #expect(copyCounted == money["copy_rows_excluded"] as? Int, "each copy row joins its original's transaction (counted once)")
        #expect(o.outstanding.amount == 0 && l.mentions.contains { $0.id == inv } && (money["invoice_is_a_movement"] as? Bool) == false,
                "the invoice is a mention, and it is recorded as settled by KS-77120")
        #expect(o.grossPaid.records.count == 6, "every occurrence of the two settlements is kept as provenance (statement, copy, report)")

        // MONEY-07: the statement has no balances: it is never shown as reconciled; the copy is not a second statement.
        #expect(l.distinctStatements.count == 1)
        let check = l.check(try #require(l.distinctStatements.first))
        #expect(check.state == .partial && check.notOnStatement.isEmpty && check.matched.count == 3 + 3)

        // MONEY-12: the same figures in the report text, the forensic schedule and the map.
        let report = CaseMoneyReport.markdown(l)
        #expect(report.contains("| Gross paid | INR 100,000.00 | 2 |") && report.contains("| Returned (refunds, reversals) | INR 50,000.00 | 1 |"))
        #expect(report.contains(CaseMoneyOutcome.netLabel) && report.contains("INR 50,000.00") && !report.lowercased().contains("loss"))
        var fa = ForensicEngagement(title: "INV-104", now: Date())
        fa.schedule = l.scheduleRows()
        let faTotals = try #require(fa.summary.byCurrency[cur])
        #expect(faTotals.gross == o.grossPaid.amount + o.fees.amount && faTotals.returned == o.returned.amount && faTotals.net == o.netOutflow)
        #expect(!FAReportRenderer.totals(fa).lowercased().contains("loss"))
        let p = try #require(await caseMapLoad(f).projection)
        let recordNodes = p.nodes.filter { $0.id.kind == .moneyRecord }
        #expect(recordNodes.count == l.records.count && recordNodes.allSatisfy { $0.kind == .money })
        #expect(recordNodes.filter { $0.money?.amount == 50_000 && $0.money?.currency == "INR" }.count == l.records.count)
        let accountNode = CaseMapNodeID(caseID: f.caseID, kind: .moneyAccount, id: a8804)
        // MONEY-01 / MONEY-09: the person view — Arjun is linked to 8804 as signatory, and that never reads as authorising.
        let rel = try #require(p.links(of: accountNode).first { $0.type == .accountRelation && $0.to == CaseMapNodeID(caseID: f.caseID, kind: .person, id: arjun) })
        #expect(rel.basis.contains("does not by itself mean authorising") && rel.status.text.contains("signatory"))
        let mine = l.forPerson(arjun)
        #expect(mine.accounts.map(\.id) == [a8804] && mine.records.count == l.records.filter { $0.payeeAccountID == a8804 || $0.payerAccountID == a8804 }.count)
        // The time view: dated records in day order; the question view: an investigator link from the question to a record.
        #expect(l.timeline.map { $0.date ?? "" } == l.timeline.map { $0.date ?? "" }.sorted())
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Was Kestrel paid twice?", actor: "Priya Nair")
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: f.caseID, type: .supports, from: CaseMapNodeID(caseID: f.caseID, kind: .moneyRecord, id: rows[1]),
                                                                to: CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: q), rationale: "The second debit", actor: "Priya Nair")
        let p2 = try #require(await caseMapLoad(f).projection)
        #expect(p2.links(of: CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: q)).contains { $0.type == .supports && $0.from.kind == .moneyRecord })
    }

    @Test("MONEY-02/03: lakh, crore and amounts in words are read with their basis; anything else stays unreadable; only classified movements enter a figure; a classification changes only by amendment")
    func readingAndClassification() async throws {
        #expect(FAMoney.read("₹2.5 lakh")?.value == 250_000 && FAMoney.read("₹2.5 lakh")?.basis.contains("lakh") == true && FAMoney.read("₹2.5 lakh")?.currency == "INR")
        #expect(FAMoney.read("INR 1.2 crore")?.value == 12_000_000)
        #expect(FAMoney.read("Rupees fifty thousand only")?.value == 50_000 && FAMoney.read("Rupees fifty thousand only")?.currency == "INR")
        #expect(FAMoney.read("one lakh twenty thousand five hundred")?.value == 120_500)
        #expect(FAMoney.read("two hundred and five dollars and fifty cents")?.value == Decimal(string: "205.5") && FAMoney.read("two hundred and five dollars and fifty cents")?.currency == "")
        #expect(FAMoney.read("12,34,567")?.value == 1_234_567 && FAMoney.read("12,34,567")?.basis == "as written")
        for bad in ["about 5k", "fifty-odd thousand", "lakh", "thousand lakh", "1.234 lakh"] { #expect(FAMoney.read(bad) == nil, "\(bad) is not read") }
        #expect(FAMoney.format(Decimal(string: "1000")!, currency: "JPY") == "1,000" && FAMoney.format(Decimal(string: "1.5")!, currency: "KWD") == "1.500"
                && FAMoney.format(Decimal(string: "12.345")!, currency: "") == "12.345")
        // The fund-flow parser keeps a negative sign; a negative-only amount and an invoice total are never assigned to a payment.
        #expect(FundsMoneyParser.parse(value: "-₹1,000", unit: nil)?.amount == -1000 && FundsMoneyParser.parse(value: "(1,000)", unit: "INR")?.amount == -1000)
        #expect(FundsMoneyParser.parse(value: "₹1,000", unit: nil)?.amount == 1000)
        let e = [FundsPaymentEdge(fromID: "A", fromLabel: "A", toID: "B", toLabel: "B", documentIDs: ["D1", "D2", "D3"])]
        let r = FundsTrace.attribute(edges: e, amounts: [FundsAmountFact(factID: "f1", documentID: "D1", value: "-₹1,000", unit: nil),
                                                          FundsAmountFact(factID: "f2", documentID: "D2", value: "₹9,000", unit: nil, context: "Invoice total ₹9,000"),
                                                          FundsAmountFact(factID: "f3", documentID: "D2", value: "₹2,000", unit: nil),
                                                          FundsAmountFact(factID: "f4", documentID: "D3", value: "₹5,000", unit: nil, context: "closing balance")])
        #expect(r.unattributed.contains { $0.documentID == "D1" && $0.reason == .negativeAmount })
        #expect(r.unattributed.contains { $0.documentID == "D2" && $0.reason == .notAMovement && $0.classes == [.invoice] })
        #expect(r.transfers.map(\.money.amount) == [2000], "D2's payment is its one movement amount; the invoice total is set aside; D3 holds only a balance")
        #expect(Set(r.unattributed.map(\.id)).count == r.unattributed.count)

        let f = try await CaseFileTests.fixture(title: "Mentions")
        let mention = try await f.file.recordMoney(caseID: f.caseID, S7.input(.unclassified, "₹ 2 lakh", payer: "Ravi", payee: "Dalmia"), actor: "Ada")
        for k in [CaseMoneyKind.invoice, .allegation, .estimate, .balance, .claim, .asset] {
            _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(k, "₹5,000", payer: "Ravi", payee: "Dalmia"), actor: "Ada")
        }
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.outcomes().byCurrency["INR"].map { $0.grossPaid.amount + $0.received.amount + $0.returned.amount } ?? 0 == 0, "no mention is paid, received or returned")
        #expect(l.record(mention)?.amount == 200_000 && l.record(mention)?.amountBasis.contains("1,00,000") == true && l.unclassified.count == 1)
        try await f.file.classifyMoney(caseID: f.caseID, id: mention, kind: .payment, actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.outcomes().byCurrency["INR"]?.grossPaid.amount == 200_000)
        await #expect(throws: CaseMoneyError.alreadyClassified) { try await f.file.classifyMoney(caseID: f.caseID, id: mention, kind: .invoice, actor: "Ada") }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_money_records SET amount = '1' WHERE id = ?;", [.uuid(mention)]) }
        // MONEY-12 amendment: the corrected record replaces the original in every figure; the original stays, inspectable.
        let fixed = try await f.file.amendMoney(caseID: f.caseID, id: mention, with: S7.input(.payment, "₹1,50,000", payer: "Ravi", payee: "Dalmia"),
                                                reason: "The bank confirmed 1.5 lakh", actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.outcomes().byCurrency["INR"]?.grossPaid.amount == 150_000 && l.amended == [mention] && l.record(mention) != nil && l.record(fixed)?.amendsRecordID == mention)
        #expect(l.outcomes().warnings.contains { $0.contains("written name only") })
    }

    @Test("MONEY-04/05/06: look-alikes without day or reference are counted once and flagged until confirmed or split; fees, outstanding and disputed are separate figures; onward hops and transfers between one holder's accounts are not added")
    func identityOutcomesAndPaths() async throws {
        let f = try await CaseFileTests.fixture(title: "Paths")
        let x1 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "1001", actor: "Ada"), x2 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "1002", actor: "Ada")
        let y = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "2001", actor: "Ada"), z = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3001", actor: "Ada")
        for (a, h) in [(x1, "Xeno Ltd"), (x2, "XENO LTD."), (y, "Yara Traders"), (z, "Zed")] {
            try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a, holderName: h, relation: .holder, basis: .investigatorNote, actor: "Ada")
        }
        let p1 = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "USD 1,000", from: x1, to: y), actor: "Ada")
        let p2 = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "USD 1,000", from: x1, to: y), actor: "Ada")
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        var o = try #require(l.outcomes().byCurrency["USD"])
        #expect(o.grossPaid.amount == 1000 && o.grossPaid.transactions == 1 && o.ifCandidatesSeparate == 1000, "counted once, flagged, the alternative said")
        try await f.file.decideMoneyIdentity(caseID: f.caseID, recordA: p1, recordB: p2, decision: .distinct, reason: "Two cheques", actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        o = try #require(l.outcomes().byCurrency["USD"])
        #expect(o.grossPaid.amount == 2000 && o.grossPaid.transactions == 2 && l.transactions().candidates.isEmpty)
        // Dated, referenced: equal payments on two days stay two; an onward hop and an internal transfer are not added.
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "USD 600", date: "2026-02-10", ref: "W-1", from: y, to: z), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.transfer, "USD 300", date: "2026-02-11", from: x1, to: x2), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.transfer, "USD 50", date: "2026-02-12", from: x1, to: z), actor: "Ada")
        let fee = try await f.file.recordMoney(caseID: f.caseID, S7.input(.fee, "USD 15", date: "2026-02-01", ref: "FEE-1", from: x1, payee: "The bank"), actor: "Ada")
        let invoice = try await f.file.recordMoney(caseID: f.caseID, S7.input(.invoice, "USD 2,500", date: "2026-01-02", ref: "INV-9", to: y), actor: "Ada")
        let part = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "USD 900", date: "2026-01-20", ref: "W-0", from: x1, to: y, settles: invoice), actor: "Ada")
        try await f.file.disputeMoney(caseID: f.caseID, id: part, note: "Yara says only 800 arrived", actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        let (by, warnings) = l.outcomes()
        o = try #require(by["USD"])
        // Hand-written: gross = 1,000 + 1,000 + 900 (X's payments to Y); onward = 600 (Y had received before paying Z); fees 15.
        #expect(o.grossPaid.amount == 2900 && o.onward.amount == 600 && o.fees.amount == 15 && o.internalTransfers.amount == 350)
        #expect(o.outstanding.amount == 1600 && o.outstanding.records == [invoice] && o.disputed.amount == 900 && o.disputed.records == [part])
        #expect(o.netOutflow == 2915 && !CaseMoneyOutcome.netLabel.lowercased().contains("loss"))
        #expect(warnings.contains { $0.contains("recorded holders differ") }, "the 50 to Zed is called a transfer between own accounts, but Zed holds 3001")
        #expect(!warnings.contains { $0.contains("USD 300.00") && $0.contains("holders differ") }, "X's two accounts: 'Xeno Ltd' and 'XENO LTD.' are the same holder by normalised name")
        #expect(l.drill(o.fees).map(\.id) == [fee] && l.drill(o.fees).first?.provenance.contains("investigator") == true)
        await #expect(throws: CaseMoneyError.notAMovement) { _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.invoice, "USD 1", settles: invoice), actor: "Ada") }
    }

    @Test("MONEY-07/08/11: statements reconcile only when complete; records off the statement and uncovered months are listed; conversions need a recorded rate and stay beside the originals; gap proposals are one per account and period")
    func statementsRatesAndGaps() async throws {
        let f = try await CaseFileTests.fixture(title: "Statements")
        let a = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "5500", currency: "EUR", actor: "Ada")
        let jan = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: a, periodStart: "2026-01-01", periodEnd: "2026-01-31", opening: "€1,000.00", closing: "€700.00",
                                                     currency: "EUR", actor: "Ada")
        _ = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: a, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: "€700.00", closing: "€700.00", currency: "EUR", actor: "Ada")
        _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: jan, text: """
            Date,Description,Reference,Debit,Credit
            2026-01-05,Payment to Hans,R1,€400.00,
            2026-01-09,Bank charges,R2,€10.00,
            2026-01-20,Receipt from Ana,R3,,€110.00
            """, actor: "Ada")
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        var c = l.check(try #require(l.statements.first { $0.id == jan }))
        #expect(c.state == .reconciled && c.difference == 0 && c.rows.count == 3, "1,000 − 400 − 10 + 110 = 700: \(c.label)")
        #expect(l.records.contains { $0.kind == .fee && $0.description?.contains("fee/charge") == true })
        // A payment of the account in January that is not on the statement: no longer reconciled (partial), never "reconciled".
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "€50", date: "2026-01-25", ref: "X9", from: a, payee: "Unknown"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "€20", date: "2026-02-14", ref: "X10", from: a, payee: "Unknown"), actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        c = l.check(try #require(l.statements.first { $0.id == jan }))
        #expect(c.state == .partial && c.notOnStatement.count == 1)
        #expect(l.missingPeriods().map { "\($0.start)–\($0.end)" } == ["2026-02-01–2026-02-28"])
        #expect(l.uncoveredMovements().map(\.month) == ["2026-02"])
        // MONEY-11: one proposal per gap; re-running and a copy of a statement add nothing.
        let first = try await f.file.syncMoneyGapProposals(caseID: f.caseID, actor: "Ada")
        _ = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: a, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: "€700.00", closing: "€700.00", currency: "EUR", actor: "Ada")
        let second = try await f.file.syncMoneyGapProposals(caseID: f.caseID, actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(first == 3 && second == 0 && l.proposals.count == 3, "missing Feb statement, Feb movements uncovered, Jan not reconciled")
        #expect(l.proposals.allSatisfy { $0.deliverable.contains("5500") && $0.state == .proposed })
        let task = try await f.svc.createAction(caseID: f.caseID, .init(title: "Request the February statement", purpose: "Gap", deliverable: "Statement"), actor: "Ada")
        try await f.file.decideMoneyGapProposal(caseID: f.caseID, id: try #require(l.proposals.first { $0.kind == .missingStatement }).id, accept: true, reason: "Asked the bank", taskID: task, actor: "Ada")
        await #expect(throws: CaseMoneyError.alreadyDecided) {
            try await f.file.decideMoneyGapProposal(caseID: f.caseID, id: try #require(l.proposals.first { $0.kind == .missingStatement }).id, accept: false, reason: "x", actor: "Ada")
        }
        // MONEY-08: two currencies are never summed; a conversion needs a recorded rate and is partial without one.
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "INR 10,000", date: "2026-01-06", ref: "I1", payer: "Ada Co", payee: "Hans"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "$100", date: "2026-01-07", ref: "D1", payer: "Ada Co", payee: "Hans"), actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        let byC = l.outcomes().byCurrency
        #expect(Set(byC.keys) == ["EUR", "INR", FAMoney.ambiguousDollar], "a bare $ is its own 'currency not stated' bucket")
        var conv = l.converted({ $0.grossPaid.amount }, figure: "Gross paid", to: "EUR")
        #expect(conv.isPartial && Set(conv.notConverted) == ["INR", FAMoney.ambiguousDollar] && conv.total == byC["EUR"]?.grossPaid.amount)
        await #expect(throws: CaseMoneyError.badRate) { _ = try await f.file.recordConversionRate(caseID: f.caseID, from: "INR", to: "EUR", rate: "abc", rateDate: "2026-01-06", rateSource: "ECB", method: "reference rate", actor: "Ada") }
        _ = try await f.file.recordConversionRate(caseID: f.caseID, from: "INR", to: "EUR", rate: "0.011", rateDate: "2026-01-06", rateSource: "ECB euro reference rate",
                                                  method: "reference rate on the payment day", actor: "Ada")
        l = try await f.file.moneyLedger(caseID: f.caseID)
        conv = l.converted({ $0.grossPaid.amount }, figure: "Gross paid", to: "EUR")
        #expect(conv.parts.first { $0.currency == "INR" }?.converted == 110 && conv.notConverted == [FAMoney.ambiguousDollar])
        #expect(conv.label.contains("ECB euro reference rate") && conv.label.contains("2026-01-06") && conv.label.contains("Partial"))
        #expect(l.outcomes().byCurrency["INR"]?.grossPaid.amount == 10_000, "the original stays the record")
        #expect(CaseMoneyReport.markdown(l).contains("1 INR = 0.011 EUR (ECB euro reference rate, 2026-01-06, reference rate on the payment day)"))
    }

    @Test("MONEY-09/10: ownership over time with sources and periods (a relationship, never an authorisation); every figure in the amount diagram is exact and drills to its documents, with the width legend stated")
    func ownershipAndFlowFigures() async throws {
        let f = try await CaseFileTests.fixture(title: "Owners")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "register.txt", text: "Vendor LLC sole member is R. Shah from 2024-01-01.")
        let a = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8834", label: "Vendor LLC operating", actor: "Ada")
        let shah = try await f.file.addPerson(caseID: f.caseID, name: "R. Shah", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let from = try #require(CaseMoneyLedger.date("2024-01-01")), to = try #require(CaseMoneyLedger.date("2025-06-30"))
        try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a, holderPersonID: shah, holderName: "R. Shah", relation: .beneficialOwner, via: "Vendor LLC",
                                               validFrom: from, validTo: to, basis: .source, sourceVersionID: doc.version, quote: "sole member is R. Shah", actor: "Ada")
        await #expect(throws: CaseWorkError.sourceNotInCase) {
            _ = try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a, holderName: "Q", relation: .controller, basis: .source, actor: "Ada")
        }
        await #expect(throws: CaseMoneyError.badPeriod) {
            _ = try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a, holderName: "Q", relation: .controller, validFrom: to, validTo: from, basis: .investigatorNote, actor: "Ada")
        }
        let l = try await f.file.moneyLedger(caseID: f.caseID)
        let rel = try #require(l.ownership.first)
        #expect(rel.holds(on: CaseMoneyLedger.date("2024-06-01")) == true && rel.holds(on: CaseMoneyLedger.date("2026-01-01")) == false)
        #expect(rel.line.contains("Beneficial owner (as asserted)") && rel.line.contains("through Vendor LLC") && rel.line.contains("2024-01-01 – 2025-06-30"))
        // A beneficial owner is not the account's holder: it does not make the account's payments "theirs".
        #expect(l.partyKeys(account: a, name: nil, on: "2024-06-01").basis.contains("no holder recorded"))
        let p = try #require(await caseMapLoad(f).projection)
        let n = try #require(p.node(CaseMapNodeID(caseID: f.caseID, kind: .moneyAccount, id: a)))
        #expect(n.wording?.contains(CaseMoneyRelation.impliesNothing) == true && n.sources.first?.sourceVersionID == nil)

        // MONEY-10: the amount diagram's party figures are exact sums with their edges and documents.
        let edges = [FundsEdgeTotal(fromID: "A", fromLabel: "Acme", toID: "V", toLabel: "Vendor", currency: "USD", total: Decimal(string: "18400.10")!, transferCount: 2,
                                    factIDs: ["f1", "f2"], documentIDs: ["d1", "d2"]),
                     FundsEdgeTotal(fromID: "A", fromLabel: "Acme", toID: "W", toLabel: "Wolf", currency: "USD", total: Decimal(string: "0.20")!, transferCount: 1,
                                    factIDs: ["f3"], documentIDs: ["d3"]),
                     FundsEdgeTotal(fromID: "A", fromLabel: "Acme", toID: "W", toLabel: "Wolf", currency: "EUR", total: 5, transferCount: 1, factIDs: ["f4"], documentIDs: ["d4"])]
        let figs = FundsTrace.nodeTotals(edges, currency: "USD")
        let acme = try #require(figs.first { $0.side == .payer && $0.partyID == "A" })
        #expect(acme.total == Decimal(string: "18400.30") && acme.documentIDs == ["d1", "d2", "d3"] && acme.edges.count == 2, "exact Decimal, euros never added")
        #expect(figs.allSatisfy { !$0.documentIDs.isEmpty && !$0.factIDs.isEmpty }, "every figure drills to its sources")
        #expect(acme.display == "Acme · USD 18,400.30")
        #expect(FundsTrace.amountLegend.contains("width is the amount") && FundsTrace.amountLegend.contains("never means how certain")
                && FundsTrace.corroborationLegend.contains("not an amount") && FundsTrace.tracingAssumption.contains("allocation assumption"))
    }
}

// MARK: - HISTORY

@MainActor
private struct S7History {
    let f: CaseFileTests.Fixture
    let prior: UUID
    let priorDoc: (version: UUID, object: UUID, blocks: [UUID])
    let service: CaseHistoryReviewService
    static func make() async throws -> S7History {
        let f = try await CaseFileTests.fixture(title: "Was Kestrel Supplies paid twice for invoice INV-104?")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt", text: "Transfer to Kestrel Supplies, a/c 8804, reference KS-77120.")
        let prior = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Closed case 2025-17", actor: "Ada", at: Date()).id
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: prior, name: "inv104-prior-case-2025-17-summary.md",
                                                            text: try S7.text("inv104-prior-case-2025-17-summary.md"))
        return S7History(f: f, prior: prior, priorDoc: doc, service: CaseHistoryReviewService(database: f.db, file: f.file, map: CaseMapService(sources: caseMapSources(f))))
    }
    func privileged(_ version: UUID) async throws {
        _ = try await SensitiveScopeRepository(database: f.db).assign(target: SensitiveScopeTarget(kind: .sourceVersion, id: version), sensitivity: .internalLevel,
                                                                      authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
    }
}

@MainActor
@Suite("Smart map S7 — prior cases and review cases (HISTORY)", .serialized)
struct SmartMapS7HistoryTests {

    @Test("HISTORY-01/07: chosen identifiers are found in another case by exact token (account 8804 in prior case 2025-17); a pattern is a candidate; a name overlap is a candidate; privileged documents are neither searched nor counted")
    func identifierOverlap() async throws {
        let h = try await S7History.make()
        _ = try await h.f.file.chooseOverlapIdentifier(caseID: h.f.caseID, kind: .accountNumber, value: "8804", actor: "Priya Nair")
        _ = try await h.f.file.chooseOverlapIdentifier(caseID: h.f.caseID, kind: .accountNumber, value: "880", actor: "Priya Nair")
        _ = try await h.f.file.chooseOverlapIdentifier(caseID: h.f.caseID, kind: .pattern, value: "INR ##,###", actor: "Priya Nair")
        await #expect(throws: CaseHistoryReviewError.badPattern) { _ = try await h.f.file.chooseOverlapIdentifier(caseID: h.f.caseID, kind: .pattern, value: "###", actor: "Priya Nair") }
        var found = try await h.service.identifierOverlaps(caseID: h.f.caseID)
        let exact = try #require(found.first { $0.identifier.value == "8804" })
        #expect(exact.basis == .exactIdentifier && exact.otherCases.map(\.caseID) == [h.prior] && exact.otherCases.first?.documents == 1)
        #expect(found.first { $0.identifier.value == "880" }?.otherCases.isEmpty == true, "a part of a number is not the number")
        let pattern = try #require(found.first { $0.identifier.kind == .pattern })
        #expect(pattern.basis.isCandidate && pattern.otherCases.map(\.caseID) == [h.prior], "INR 18,000 matches the pattern — a candidate")
        #expect(!exact.summary.contains("18,000") && !exact.summary.contains("credit note"), "counts and case names only, never a passage")
        // HISTORY-01: a person or organisation overlap is a same-name candidate; a phone or email is exact.
        let named = CaseOverlapEntity(entityID: UUID(), kind: "person", value: "Arjun Mehta", documentsInThisCase: 1, otherCases: [], documentsInNoCase: 0)
        let phone = CaseOverlapEntity(entityID: UUID(), kind: "phoneNumber", value: "+91 98100 00000", documentsInThisCase: 1, otherCases: [], documentsInNoCase: 0)
        #expect(named.isCandidate && named.basis == .sameName && !phone.isCandidate)
        // HISTORY-07: labelled privileged, the prior case's document is not searched or counted — and nothing says one was left out.
        try await h.privileged(h.priorDoc.version)
        found = try await h.service.identifierOverlaps(caseID: h.f.caseID)
        #expect(found.allSatisfy { $0.otherCases.isEmpty } && found.allSatisfy { !$0.summary.contains("1 document") })
    }

    @Test("HISTORY-02/03: a history set separate from search (no kind for AI memory); explicit references pin origin, record and mode; reading re-checks access; the same-case write checks still refuse another case's records")
    func historySetAndReferences() async throws {
        let h = try await S7History.make()
        let f = h.f
        await #expect(throws: CaseHistoryReviewError.sameCase) { _ = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: f.caseID, purpose: "x", scope: .records, actor: "Ada") }
        await #expect(throws: CaseHistoryReviewError.originNotFound) { _ = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: UUID(), purpose: "x", scope: .records, actor: "Ada") }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_history_sources (id, case_id, source_kind, purpose, permitted_scope, selected_by, selected_at) VALUES (?,?,?,?,?,?,?);",
                                [.uuid(UUID()), .uuid(f.caseID), .text("aiMemory"), .text("what the assistant remembers"), .text("records"), .text("Ada"), .real(0)])
        }
        #expect(!CaseHistorySourceKind.allCases.map(\.rawValue).contains { $0.lowercased().contains("ai") || $0.lowercased().contains("memory") })
        let ext = try await f.file.addHistorySource(caseID: f.caseID, kind: .external, externalName: "Company register (configured lookup)", purpose: "Directors of Kestrel",
                                                    scope: .identifiersOnly, actor: "Ada")
        #expect(try await f.file.historySources(caseID: f.caseID).first { $0.id == ext }?.kind.isDocumentary == false)
        let narrow = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: h.prior, purpose: "Same account?", scope: .identifiersOnly, actor: "Ada")
        let src = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: h.prior, purpose: "Earlier dispute on 8804", scope: .records, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: h.prior, text: "A payment of INR 18,000 to account 8804 was disputed", actor: "Ada")
        let origin = CaseMapNodeID(caseID: h.prior, kind: .allegation, id: q)
        await #expect(throws: CaseHistoryReviewError.scopeTooNarrow) { _ = try await f.file.addCrossReference(caseID: f.caseID, historySourceID: narrow, origin: origin, mode: .live, purpose: "x", actor: "Ada") }
        await #expect(throws: CaseHistoryReviewError.recordNotInOrigin) {
            _ = try await f.file.addCrossReference(caseID: f.caseID, historySourceID: src, origin: CaseMapNodeID(caseID: h.prior, kind: .allegation, id: UUID()), mode: .live, purpose: "x", actor: "Ada")
        }
        let ref = try await f.file.addCrossReference(caseID: f.caseID, historySourceID: src, origin: origin, mode: .live, purpose: "Compare with the earlier dispute", actor: "Ada")
        var view = try await h.service.resolve(caseID: f.caseID, referenceID: ref)
        #expect(view.isAvailable && view.title?.contains("18,000") == true && view.sources.isEmpty, "records scope: the record, not its source passages")
        // The existing same-case write check is not weakened: a map link from this case to the other case's record is refused.
        let mine = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice?", actor: "Ada")
        await #expect(throws: (any Error).self) {
            _ = try await CaseMapRepository(database: f.db).addLink(caseID: f.caseID, type: .supports, from: origin, to: CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: mine),
                                                                    rationale: "x", actor: "Ada")
        }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_cross_references SET origin_record_id = 'x' WHERE id = ?;", [.uuid(ref)]) }
        // Access withdrawn: the reference stays, unavailable — nothing of the other case was kept here.
        try await f.file.withdrawHistorySource(caseID: f.caseID, id: src, reason: "No longer authorised", actor: "Ada")
        view = try await h.service.resolve(caseID: f.caseID, referenceID: ref)
        #expect(!view.isAvailable && view.title == nil && view.wording == nil)
        #expect(try await S7.count(f.db, "SELECT COUNT(*) FROM case_cross_references WHERE case_id = ? AND purpose LIKE '%18,000%';", [.uuid(f.caseID)]) == 0)
    }

    @Test("HISTORY-04: comparison shows shared exact identifiers, same-name candidates, periods and limits — and records nothing in either case")
    func comparison() async throws {
        let h = try await S7History.make()
        let f = h.f
        _ = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8804", actor: "Ada")
        _ = try await f.file.addMoneyAccount(caseID: h.prior, identifier: "A/c 8804", actor: "Ada")
        _ = try await f.file.recordMoney(caseID: f.caseID, S7.input(.payment, "INR 50,000", date: "2026-03-06", ref: "KS-77120", payer: "Northwind", payee: "Kestrel"), actor: "Ada")
        _ = try await f.file.recordMoney(caseID: h.prior, S7.input(.payment, "INR 18,000", date: "2025-09-02", ref: "CN-11", payer: "Northwind", payee: "Kestrel"), actor: "Ada")
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Arjun Mehta", role: .other, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.addPerson(caseID: h.prior, name: "Arjun  Mehta", role: .other, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let src = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: h.prior, purpose: "Earlier dispute", scope: .records, actor: "Ada")
        let before = (try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseID)]),
                      try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(h.prior)]))
        let c = try await h.service.compare(caseID: f.caseID, historySourceID: src)
        #expect(c.similarities.contains { $0.aspect == "Account identifier" && $0.note.contains("exact") })
        #expect(c.similarities.contains { $0.aspect == "Name" && $0.note.contains("candidate only") })
        #expect(c.differences.contains { $0.aspect == "When the money records fall" && $0.thisCase == "2026-03-06" && $0.otherCase == "2025-09-02" })
        #expect(!c.similarities.contains { $0.aspect == "Payment reference" }, "different references are not a similarity")
        #expect(c.limitations.contains(CaseCrossCaseAccess.scopeNote) && CaseHistoryComparisonCrossCase.caution.contains("not the same person"))
        let after = (try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseID)]),
                     try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(h.prior)]))
        let decisions = try await S7.count(f.db, "SELECT COUNT(*) FROM investigation_identity_decisions;", [])
        #expect(before == after && decisions == 0)
        #expect(try await S7.count(f.db, "SELECT COUNT(*) FROM case_person_identity_decisions;", []) == 0, "no same-person decision is made")
    }

    @Test("HISTORY-05/06/08: a review case examines another investigation without changing it; a pinned reference shows only what was recorded then; findings trace back to the original and the original lists the review; the review exports on its own")
    func reviewCase() async throws {
        let h = try await S7History.make()
        let f = h.f
        let origin = h.prior
        let allegation = try await f.file.addAllegation(caseID: origin, text: "The 2025 payment was disputed", actor: "Ravi")
        _ = try await f.svc.linkEvidence(caseID: origin, allegationID: allegation, evidenceRef: h.priorDoc.version.uuidString, label: "Summary", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: h.priorDoc.version, quote: "A payment of INR 18,000 to account 8804 was disputed and later settled by a credit note."),
                                         actor: "Ravi")
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let recorded = try await history.record(caseID: origin, kind: .milestone, name: "Closed", actor: "Ravi")
        let later = try await f.file.addAllegation(caseID: origin, text: "Added after the case closed", actor: "Ravi")
        let originFence = try await CaseMapRepository(database: f.db).revisionFence(caseID: origin)
        let originActions = try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(origin)])

        let review = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Review of case 2025-17", actor: "Sunil Rao", at: Date()).id
        let started = try await f.file.startReview(caseID: review, of: origin, purpose: "Was the 2025 dispute handled properly?", actor: "Sunil Rao")
        let pinned = try await h.service.pinAsKnownAt(caseID: review, historySourceID: started.historySource, origin: CaseMapNodeID(caseID: origin, kind: .allegation, id: allegation),
                                                      at: recorded.recordedAt.addingTimeInterval(1), purpose: "What the investigator had", actor: "Sunil Rao")
        let laterRef = try await f.file.addCrossReference(caseID: review, historySourceID: started.historySource, origin: CaseMapNodeID(caseID: origin, kind: .allegation, id: later),
                                                          mode: .snapshot, pinnedCheckpointID: recorded.id, purpose: "Was it known?", actor: "Sunil Rao")
        let view = try await h.service.resolve(caseID: review, referenceID: pinned)
        #expect(view.isAvailable && view.title?.contains("The 2025 payment was disputed") == true && view.asOf.contains("Recorded state"), "\(view.state) \(String(describing: view.title))")
        let notKnown = try await h.service.resolve(caseID: review, referenceID: laterRef)
        #expect(notKnown.state == .unavailable("The record is not in the pinned recorded state."), "later material is not shown as known then")
        let known = try await h.service.originKnownAt(caseID: review, referenceID: pinned, at: recorded.recordedAt.addingTimeInterval(1))
        if case .recorded(let s, _) = known.knownAt { #expect(s.id == recorded.id) } else { Issue.record("expected a recorded state, got \(known.knownAt)") }
        #expect(known.absentHistory.contains("not recorded before"))
        await #expect(throws: CaseHistoryReviewError.self) {
            _ = try await h.service.pinAsKnownAt(caseID: review, historySourceID: started.historySource, origin: CaseMapNodeID(caseID: origin, kind: .allegation, id: allegation),
                                                 at: Date(timeIntervalSince1970: 0), purpose: "Too early", actor: "Sunil Rao")
        }

        let finding = try await f.file.recordReviewFinding(caseID: review, referenceID: pinned, assessment: .incomplete,
                                                           text: "The credit note was never obtained.", actor: "Sunil Rao")
        await #expect(throws: CaseHistoryReviewError.notAReview) {
            let other = try await f.file.addHistorySource(caseID: f.caseID, kind: .case, originCaseID: origin, purpose: "p", scope: .records, actor: "Ada")
            let r = try await f.file.addCrossReference(caseID: f.caseID, historySourceID: other, origin: CaseMapNodeID(caseID: origin, kind: .allegation, id: allegation), mode: .live, purpose: "p", actor: "Ada")
            _ = try await f.file.recordReviewFinding(caseID: f.caseID, referenceID: r, assessment: .agrees, text: "x", actor: "Ada")
        }
        // The original case is unchanged by the review.
        #expect(try await CaseMapRepository(database: f.db).revisionFence(caseID: origin) == originFence)
        #expect(try await S7.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(origin)]) == originActions)
        #expect(try await S7.count(f.db, "SELECT COUNT(*) FROM case_review_findings WHERE case_id = ?;", [.uuid(origin)]) == 0)

        let trace = try await h.service.trace(caseID: review, findingID: finding)
        #expect(trace.reference.isAvailable && trace.reference.title?.contains("The 2025 payment was disputed") == true && trace.originalDecision.contains("—"))
        let back = try await h.service.reviewsReferencing(originCaseID: origin, record: CaseMapNodeID(caseID: origin, kind: .allegation, id: allegation))
        let rawRefs = try await f.db.query("SELECT origin_case_id, origin_kind, origin_record_id FROM case_cross_references;", []).map { "\($0.string(0) ?? "")|\($0.string(1) ?? "")|\($0.string(2) ?? "")" }
        #expect(back.first { $0.reviewCaseID == review }?.findings == 1 && back.count == 2, "both cases referencing it are listed (titles and counts only): \(back) \(rawRefs)")
        let export = try await h.service.reviewExport(caseID: review)
        #expect(export.contains("Reviews: Closed case 2025-17") && export.contains("The credit note was never obtained.") && export.contains("recorded by Sunil Rao")
                && export.contains("changed nothing in the original case") && export.contains("reviewFindingRecorded") && export.contains("credit note"))

        // HISTORY-07: labelled privileged later, the source is withheld from the recorded state, the reference and the export.
        let logical = try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(h.priorDoc.version)]).first?.uuid(0))
        let docRef = try await f.file.addCrossReference(caseID: review, historySourceID: started.historySource, origin: CaseMapNodeID(caseID: origin, kind: .document, id: logical),
                                                        mode: .live, purpose: "The summary itself", actor: "Sunil Rao")
        let docBefore = try await h.service.resolve(caseID: review, referenceID: docRef)
        #expect(docBefore.isAvailable && docBefore.sources.contains { $0.sourceVersionID == h.priorDoc.version })
        try await h.privileged(h.priorDoc.version)
        let docAfter = try await h.service.resolve(caseID: review, referenceID: docRef)
        #expect(docAfter.isAvailable && docAfter.sources.isEmpty && docAfter.note?.contains("privileged") == true)
        let opened = try await history.open(id: recorded.id, caseID: origin)
        #expect(opened.privilegedVersions == [h.priorDoc.version] && opened.accessNote?.contains("privileged") == true)
        #expect(!opened.projection.nodes.flatMap(\.sources).contains { $0.quote?.contains("credit note") == true })
        let again = try await h.service.resolve(caseID: review, referenceID: pinned)
        #expect(again.isAvailable && !again.sources.contains { $0.sourceVersionID == h.priorDoc.version })
        #expect(!(try await h.service.reviewExport(caseID: review)).contains("settled by a credit note"))
    }
}
