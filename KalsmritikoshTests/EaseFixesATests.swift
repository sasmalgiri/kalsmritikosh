//
//  EaseFixesATests.swift
//  KalsmritikoshTests
//
//  Ease fixes A (AI-off assessment 2026-11-15, friction points 2 and 3): the bank statement import from a file (preview,
//  refused rows with why, all or nothing, receipt, tied to its case document or recorded as supplied), explicit money kinds
//  (an unclassified entry is counted as "not counted"), "Change kind…" as a recorded revision that moves the figures, the
//  source document of a hand entry, and the case check reading amounts in any currency (FAMoney) plus the rule that
//  compares a document's payments with the case's money records. Throwaway ledgers; expected values written by hand — the
//  INV-104 witness quote comes from the fixture's separate answer key, which product code never reads. AI off: nothing here
//  calls a model or the network.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

private enum EF {
    typealias F = CaseContradictionFinder
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
    static func doc(_ text: String) -> F.Document { F.Document(objectID: UUID(), sourceVersionID: UUID(), text: text) }
    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) ?? -1 }
    static let at = Date(timeIntervalSince1970: 1_794_000_000)   // a fixed instant; days are stored as UTC calendar days

    static let csv = """
    Date,Description,Reference,Debit,Credit
    2026-03-06,"Transfer to Kestrel Supplies Pvt Ltd, a/c 8804",UTR KS-77120,"50,000",
    2026-03-11,"Transfer to Kestrel Supplies Pvt Ltd, a/c 8804",UTR KS-77985,"50,000",
    2026-03-19,"Refund from Kestrel Supplies Pvt Ltd, a/c 8804",UTR KS-78410,,"50,000"
    """
    /// Row 1 good; row 2 both a debit and a credit; row 3 a closing balance line; row 4 dated outside March.
    static let badCSV = """
    Date,Description,Reference,Debit,Credit
    2026-03-06,Transfer to Kestrel,UTR 1,"50,000",
    2026-03-08,Adjustment,UTR 2,100,100
    2026-03-31,Closing balance,,,"1,00,000"
    2026-04-02,Transfer to Kestrel,UTR 3,"10,000",
    """
}

@Suite("Ease fixes A — money entry without AI, conflict checks in any currency", .serialized)
struct EaseFixesATests {
    typealias F = CaseContradictionFinder

    // MARK: - Statement import

    @Test("Statement import happy path: a case document with the same bytes is found; account, statement and three rows are written; the figures follow")
    func statementImportHappyPath() async throws {
        let f = try await CaseFileTests.fixture(title: "Was Kestrel paid twice?")
        let seeded = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement-march.csv", text: EF.csv)
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE id = ?;", [.text(EF.sha(EF.csv)), .uuid(seeded.version)])
        let match = try await f.file.moneyCaseDocument(caseID: f.caseID, sha256: EF.sha(EF.csv))
        #expect(match?.id == seeded.version && match?.name == "statement-march.csv")
        #expect(try await f.file.moneyCaseDocument(caseID: f.caseID, sha256: EF.sha("other bytes")) == nil)

        let preview = CaseMoneyStatementParser.preview(EF.csv, currency: "INR")
        #expect(preview.canImport && preview.rows.count == 3 && preview.refused.isEmpty)
        #expect(preview.firstDay == "2026-03-06" && preview.lastDay == "2026-03-19")
        #expect(preview.rows.map(\.kind) == [.payment, .payment, .refund])
        #expect(preview.rows[0].reading == "INR 50,000.00")

        var req = CaseMoneyStatementImport(accountID: nil, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "inr", text: EF.csv, fileName: "statement-march.csv")
        req.newAccountIdentifier = "3391"; req.newAccountInstitution = "Western Coast Bank"
        req.fileSHA256 = EF.sha(EF.csv); req.sourceVersionID = match?.id
        let receipt = try await f.file.importStatement(caseID: f.caseID, req, actor: "Ada", at: EF.at)
        #expect(receipt.written && receipt.imported.count == 3 && receipt.refused.isEmpty && receipt.notRead == 0)
        #expect(receipt.summary.hasPrefix("3 row(s) imported, 0 refused"))
        #expect(receipt.source.contains("a document of this case"))

        let l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.accounts.count == 1 && l.accounts[0].identifier == "3391" && l.accounts[0].currency == "INR")
        #expect(l.statements.count == 1 && l.statements[0].sourceVersionID == seeded.version && l.statements[0].currency == "INR")
        #expect(l.records.count == 3 && l.records.allSatisfy { $0.sourceVersionID == seeded.version && $0.statementID == receipt.statementID })
        let inr = try #require(l.outcomes().byCurrency["INR"])
        #expect(inr.grossPaid.amount == EF.dec("100000") && inr.returned.amount == EF.dec("50000") && inr.netOutflow == EF.dec("50000"))
        #expect(try await EF.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = 'moneyStatementImported';", [.uuid(f.caseID)]) == 1)
    }

    @Test("Preview lists every refused row with why (both columns, balance line, outside the period) and the import is refused")
    func statementPreviewRefusal() {
        let p = CaseMoneyStatementParser.preview(EF.badCSV, currency: "INR", period: ("2026-03-01", "2026-03-31"))
        #expect(p.rows.count == 4)
        #expect(!p.canImport)
        #expect(p.refused.map(\.row) == [2, 3, 4])
        #expect(p.rows[0].refusal == nil && p.rows[0].kind == .payment)
        #expect(p.rows[1].refusal?.contains("both a debit and a credit") == true && p.rows[1].kind == nil)
        #expect(p.rows[2].refusal?.contains("balance or total line") == true)
        #expect(p.rows[3].refusal?.contains("outside the statement period") == true)
        // A file with no usable header is a file problem, not rows.
        let none = CaseMoneyStatementParser.preview("Narration,Amount\nRent,100", currency: "INR")
        #expect(!none.fileProblems.isEmpty && none.rows.isEmpty && !none.canImport)
        // The pasted-text importer refuses on the same list, first reason first (unchanged behaviour).
        let parsed = CaseMoneyStatementParser.rows(EF.badCSV)
        #expect(CaseMoneyStatementParser.refusals(parsed).first?.row == 2)
    }

    @Test("All or nothing: a refused row writes no account, statement or row, and the receipt says why")
    func statementImportAllOrNothing() async throws {
        let f = try await CaseFileTests.fixture()
        var req = CaseMoneyStatementImport(accountID: nil, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "INR", text: EF.badCSV, fileName: "bad.csv")
        req.newAccountIdentifier = "3391"
        let receipt = try await f.file.importStatement(caseID: f.caseID, req, actor: "Ada", at: EF.at)
        #expect(!receipt.written && receipt.imported.isEmpty && receipt.refused.count == 3)
        #expect(receipt.summary.hasPrefix("Nothing was imported: 3 row(s) refused."))
        #expect(receipt.summary.contains("both a debit and a credit"))
        for table in ["case_money_accounts", "case_money_statements", "case_money_records"] {
            #expect(try await EF.count(f.db, "SELECT COUNT(*) FROM \(table) WHERE case_id = ?;", [.uuid(f.caseID)]) == 0, "\(table)")
        }
        // A duplicate account inside the one savepoint also leaves nothing behind.
        _ = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", actor: "Ada")
        var dup = CaseMoneyStatementImport(accountID: nil, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "INR", text: EF.csv, fileName: "s.csv")
        dup.newAccountIdentifier = "A/c 3391"
        await #expect(throws: CaseMoneyError.self) { _ = try await f.file.importStatement(caseID: f.caseID, dup, actor: "Ada", at: EF.at) }
        #expect(try await EF.count(f.db, "SELECT COUNT(*) FROM case_money_statements WHERE case_id = ?;", [.uuid(f.caseID)]) == 0)
        #expect(try await EF.count(f.db, "SELECT COUNT(*) FROM case_money_records WHERE case_id = ?;", [.uuid(f.caseID)]) == 0)
    }

    @Test("Receipt counts: imported rows, amounts not read (kept as written, in no figure), a chosen kind, and a supplied file recorded with who and its SHA-256")
    func statementImportReceiptCounts() async throws {
        let f = try await CaseFileTests.fixture()
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", actor: "Ada")
        let text = "Date,Description,Debit,Credit\n2026-03-06,Transfer,\"1,085\",\n2026-03-07,Card fee,250,\n2026-03-08,Money in,,400"
        var req = CaseMoneyStatementImport(accountID: acct, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "", text: text, fileName: "mine.csv")
        req.fileSHA256 = EF.sha(text)
        req.kindOverrides = [3: .transfer]
        let r = try await f.file.importStatement(caseID: f.caseID, req, actor: "Ada", at: EF.at)
        #expect(r.written && r.imported.count == 3 && r.refused.isEmpty && r.notRead == 1)
        #expect(r.summary.contains("1 amount(s) could not be read without guessing"))
        #expect(r.source.contains("supplied by Ada") && r.source.contains(String(EF.sha(text).prefix(16))))
        let l = try await f.file.moneyLedger(caseID: f.caseID)
        let byRow = Dictionary(uniqueKeysWithValues: l.records.compactMap { rec in rec.statementRow.map { ($0, rec) } })
        #expect(byRow[1]?.amount == nil && byRow[1]?.amountText == "1,085")
        #expect(byRow[2]?.kind == .fee)
        #expect(byRow[3]?.kind == .transfer && byRow[3]?.description?.contains("kind chosen by Ada in the import preview") == true)
        #expect(l.statements.first?.sourceVersionID == nil && l.statements.first?.sourceName?.contains("supplied by Ada") == true)
    }

    // MARK: - Explicit kinds and reclassify

    @Test("An unclassified entry is shown as not counted; Change kind writes a revision with who and when and moves the figures")
    @MainActor
    func reclassifyWritesRevisionAndMovesTotals() async throws {
        let f = try await CaseFileTests.fixture()
        var input = CaseMoneyRecordInput(kind: .unclassified, amountText: "INR 50,000")
        input.date = "2026-03-06"; input.payeeName = "Kestrel"
        let id = try await f.file.recordMoney(caseID: f.caseID, input, actor: "Ada", at: EF.at)
        var l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.unclassified.map(\.id) == [id])
        #expect(l.outcomes().byCurrency.isEmpty)
        #expect(CaseMoneyTool.notCountedText(l.unclassified.count) == "1 entry not counted: choose a kind (“Change kind…”).")
        #expect(CaseMoneyTool.notCountedText(3).hasPrefix("3 entries not counted"))
        #expect(CaseMoneyTool.kindTitle(.unclassified).contains("counts in no figure"))

        // Unclassified → payment: classified in place, its row before and after kept with the actor and time.
        let same = try await f.file.reclassifyMoney(caseID: f.caseID, id: id, kind: .payment, reason: "The statement shows a debit", actor: "Ada", at: EF.at)
        #expect(same == id)
        let revs = try await CaseRecordRevisions.revisions(f.db, caseID: f.caseID, kind: "moneyRecord", recordID: id)
        #expect(revs.count == 1)
        #expect(revs.first?.value("kind").before == "unclassified" && revs.first?.value("kind").after == "payment")
        #expect(revs.first?.actor == "Ada" && revs.first?.recordedAt == EF.at)
        l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.unclassified.isEmpty && l.outcomes().byCurrency["INR"]?.grossPaid.amount == EF.dec("50000"))

        // Payment → refund: an amendment of the new kind; the original stays, out of every figure.
        let newID = try await f.file.reclassifyMoney(caseID: f.caseID, id: id, kind: .refund, reason: "It was money back", actor: "Ben", at: EF.at.addingTimeInterval(60))
        #expect(newID != id)
        l = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(l.amended.contains(id) && l.record(id)?.kind == .payment)
        let amended = try #require(l.record(newID))
        #expect(amended.kind == .refund && amended.amendsRecordID == id && amended.recordedBy == "Ben")
        #expect(amended.amendReason?.hasPrefix("Reclassified from Payment (money out) to Refund: It was money back") == true)
        let inr = try #require(l.outcomes().byCurrency["INR"])
        #expect(inr.grossPaid.amount == 0 && inr.returned.amount == EF.dec("50000"))
        await #expect(throws: CaseMoneyError.sameKind) { _ = try await f.file.reclassifyMoney(caseID: f.caseID, id: newID, kind: .refund, reason: "x", actor: "Ada") }
        await #expect(throws: CaseMoneyError.notUnclassified) { _ = try await f.file.reclassifyMoney(caseID: f.caseID, id: newID, kind: .unclassified, reason: "x", actor: "Ada") }
        await #expect(throws: CaseFileError.self) { _ = try await f.file.reclassifyMoney(caseID: f.caseID, id: newID, kind: .payment, reason: " ", actor: "Ada") }
    }

    @Test("A hand entry's source document and page are stored and named in its provenance")
    @MainActor
    func sourceLinkStored() async throws {
        let f = try await CaseFileTests.fixture()
        let seeded = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bank-letter.pdf", text: "We paid INR 50,000 on 6 March 2026.")
        let docs = try await f.file.moneyCaseDocuments(caseID: f.caseID)
        #expect(docs.map(\.name) == ["bank-letter.pdf"])
        var input = CaseMoneyRecordInput(kind: .payment, amountText: "INR 50,000")
        input.sourceVersionID = docs[0].id
        input.sourceName = CaseMoneyTool.sourceName(docs[0].name, locator: " p. 3 ")
        input.quote = "We paid INR 50,000"
        let id = try await f.file.recordMoney(caseID: f.caseID, input, actor: "Ada", at: EF.at)
        let r = try #require(try await f.file.moneyLedger(caseID: f.caseID).record(id))
        #expect(r.sourceVersionID == seeded.version && r.sourceName == "bank-letter.pdf, p. 3" && r.quote == "We paid INR 50,000")
        #expect(r.provenance.contains("bank-letter.pdf, p. 3"))
        #expect(CaseMoneyTool.sourceName("a.pdf", locator: "") == "a.pdf")
        // A document outside the case is refused.
        var outside = input
        outside.sourceVersionID = try await CaseFileTestSources.seed(f.db)
        await #expect(throws: CaseWorkError.self) { _ = try await f.file.recordMoney(caseID: f.caseID, outside, actor: "Ada") }
    }

    // MARK: - Amounts in any currency

    @Test("INR / ₹ amounts paid to one person are compared; the values carry their currency")
    func inrConflictFound() {
        let a = EF.doc("The company paid Ravi Kumar ₹50,000 for the contract.")
        let b = EF.doc("Ravi Kumar received INR 75,000 for the contract.")
        let found = F.ruleFindings([a, b]).filter { $0.kind == .amount }
        #expect(found.count == 1)
        #expect(Set(found.map(\.valueA) + found.map(\.valueB)) == ["INR 50,000.00", "INR 75,000.00"])
        #expect(found.first?.subject == "Ravi Kumar")
        // The same amount written two ways is not a conflict.
        #expect(F.ruleFindings([EF.doc("The company paid Ravi Kumar ₹50,000 for the contract."), EF.doc("Ravi Kumar received 50,000 rupees for the contract.")])
            .filter { $0.kind == .amount }.isEmpty)
    }

    @Test("Lakh and crore are read exactly; equal amounts written in lakh and in figures do not conflict")
    func lakhCrore() {
        let lakh = F.ruleFindings([EF.doc("The company paid Ravi Kumar Rs 2.5 lakh for the contract."), EF.doc("Ravi Kumar received Rs. 4 lakh for the contract.")])
            .filter { $0.kind == .amount }
        #expect(lakh.count == 1)
        #expect(Set([lakh.first?.valueA, lakh.first?.valueB]) == ["INR 250,000.00", "INR 400,000.00"])
        let crore = F.ruleFindings([EF.doc("The company paid Ravi Kumar ₹1.2 crore for the land."), EF.doc("Ravi Kumar received ₹1.5 crore for the land.")])
            .filter { $0.kind == .amount }
        #expect(crore.count == 1)
        #expect(F.ruleFindings([EF.doc("The company paid Ravi Kumar ₹2.5 lakh for the contract."), EF.doc("Ravi Kumar received ₹2,50,000 for the contract.")])
            .filter { $0.kind == .amount }.isEmpty)
        let read = F.amounts(in: "a fee of ₹2.5 lakh and €1,200 and 5,000 rupees")
        #expect(read.map(\.currency) == ["INR", "EUR", "INR"])
        #expect(read.map(\.value) == [EF.dec("250000"), EF.dec("1200"), EF.dec("5000")])
    }

    @Test("€ and ₹ amounts are never compared with each other; ¥ is never read")
    func euroVersusRupeeNeverCompared() {
        let found = F.ruleFindings([EF.doc("The company paid Ravi Kumar €50,000 for the contract."), EF.doc("Ravi Kumar received ₹80,000 for the contract.")])
        #expect(found.filter { $0.kind == .amount }.isEmpty)
        #expect(F.amounts(in: "paid ¥50,000 to him").isEmpty)
    }

    @Test("An ambiguous “1,085” with no currency to decide it is not an amount and is not compared")
    func ambiguousNotCompared() {
        let found = F.ruleFindings([EF.doc("The company paid Ravi Kumar 1,085 for the contract."), EF.doc("Ravi Kumar received INR 2,000 for the contract.")])
        #expect(found.filter { $0.kind == .amount }.isEmpty)
        #expect(F.amounts(in: "The company paid Ravi Kumar 1,085 for the contract.").isEmpty)
        // With a three-decimal currency stated, FAMoney decides it.
        #expect(F.amounts(in: "paid KWD 1,085").first?.value == EF.dec("1.085"))
        // A bare grouped figure takes the sentence's one named currency.
        #expect(F.amounts(in: "Amounts in rupees: he was paid 1,00,000 in March.").first?.value == EF.dec("100000"))
    }

    // MARK: - A document's payments vs the case's money records (INV-104)

    @Test("INV-104: the witness's “one payment” against the two debits in the case's money records is found by the rules, both sources kept")
    func inv104WitnessVersusTwoDebits() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let key = try EF.key()
            let discrepancy = try #require(key["discrepancy"] as? [String: Any])
            let witnessQuote = try #require(discrepancy["witness_quote"] as? String)

            let f = try await CaseFileTests.fixture(title: "Was Kestrel Supplies paid twice for invoice INV-104?")
            var docs: [F.Document] = []
            var byName: [String: (version: UUID, object: UUID)] = [:]
            for name in SupplierINV104Fixture.documentNames {
                let text = try EF.text(name)
                let s = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: name, text: text)
                byName[name] = (s.version, s.object)
                docs.append(F.Document(objectID: s.object, sourceVersionID: s.version, text: text, fileName: name, date: F.documentDate([text])))
            }
            let stmt = try #require(byName[SupplierINV104Fixture.bankStatement])
            let owner = try #require(byName["inv104-account-ownership-8804.md"])
            let a8804 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8804", institution: "Western Coast Bank", currency: "INR", sourceVersionID: owner.version, actor: "Priya Nair")
            try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a8804, holderName: "Kestrel Supplies Pvt Ltd", relation: .holder, basis: .source,
                                                   sourceVersionID: owner.version, quote: "Account holder: Kestrel Supplies Pvt Ltd", actor: "Priya Nair")
            var req = CaseMoneyStatementImport(accountID: nil, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "INR",
                                               text: try EF.text(SupplierINV104Fixture.bankStatement), fileName: SupplierINV104Fixture.bankStatement)
            req.newAccountIdentifier = "3391"; req.newAccountInstitution = "Western Coast Bank"; req.sourceVersionID = stmt.version
            let receipt = try await f.file.importStatement(caseID: f.caseID, req, actor: "Priya Nair", at: EF.at)
            #expect(receipt.written && receipt.imported.count == 3)

            let movements = try await f.file.moneyLedger(caseID: f.caseID).contradictionMovements()
            #expect(movements.filter { $0.kind == "payment" }.count == 2)
            let found = F.moneyRecordFindings(docs, movements: movements)
            #expect(found.count == 1, "only the witness disagrees with the money records; FR-12's two debits agree")
            let pair = try #require(found.first)
            #expect(pair.kind == .count && pair.provenance == .rules)
            #expect(pair.quoteA == witnessQuote)
            #expect(pair.valueA == "1 payment" && pair.valueB == "2 payments")
            #expect(pair.objectA == byName["inv104-witness-statement-meera-shah.md"]?.object && pair.objectB == stmt.object)
            #expect(pair.quoteB.contains("UTR KS-77120") && pair.quoteB.contains("UTR KS-77985") && !pair.quoteB.contains("KS-78410"))
            #expect(pair.subject.contains("Kestrel"))
            #expect(pair.description.contains("2026-03-06") && pair.description.contains("2026-03-11") && pair.description.contains("March"))
            let c = pair.contradiction()
            #expect(c.claimA == witnessQuote && c.evidenceA != nil && c.evidenceB != nil && c.evidenceA != c.evidenceB)
            #expect(F.provenance(of: c) == .rules && F.kindLabel(of: c) == "Count")

            // Through the case check itself: stored with both sides, in the case's scope; a rerun adds nothing twice.
            let evidence = EvidenceStore(database: f.db)
            var pass = CaseContradictionPass(documents: { _ in docs }, gate: { _ in nil }, reader: { nil })
            let file = f.file
            let caseID = f.caseID
            pass.moneyMovements = { id in try await file.moneyLedger(caseID: id).contradictionMovements() }
            let desk = InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                            contradictions: ContradictionsRepository(database: f.db), gaps: GapNodeRepository(database: f.db),
                                                            reviews: InvestigationDeskReviewRepository(database: f.db), pass: pass)
            let run = try await desk.findContradictions(caseID: caseID, at: EF.at)
            #expect(run.moneyFindings == 1 && run.moneyMovementsCompared == movements.count)
            #expect(run.ruleFindings.contains { $0.quoteA == witnessQuote })
            let items = try await desk.contradictions(caseID: caseID)
            #expect(items.filter { $0.contradiction.claimA == witnessQuote }.count == 1)
            _ = try await desk.findContradictions(caseID: caseID, at: EF.at)
            #expect(try await desk.contradictions(caseID: caseID).count == items.count)
        }
    }

    @Test("Payment-count guards: the same count, a different currency, a negated count, a total that matches, an undated payment in a named month")
    func paymentCountGuards() {
        let v = UUID()
        let stmt = F.Document(objectID: UUID(), sourceVersionID: v, text: "| 2026-03-06 | To Kestrel | R1 | INR 50,000 |\n| 2026-03-11 | To Kestrel | R2 | INR 50,000 |")
        func pay(_ day: String?, _ ref: String, _ cur: String = "INR") -> F.MoneyMovement {
            F.MoneyMovement(kind: "payment", amount: 50_000, currency: cur, day: day, payee: ["Kestrel Supplies Pvt Ltd"],
                            sources: [.init(sourceVersionID: v, dateText: day, amountText: "INR 50,000", reference: ref, quote: nil)])
        }
        let two = [pay("2026-03-06", "R1"), pay("2026-03-11", "R2")]
        func found(_ sentence: String, _ m: [F.MoneyMovement] = two) -> [F.Finding] { F.moneyRecordFindings([EF.doc(sentence), stmt], movements: m) }
        #expect(found("I approved two payments of INR 50,000 to Kestrel in March.").isEmpty)
        #expect(found("I approved one payment of €50,000 to Kestrel in March.").isEmpty)
        #expect(found("I did not approve one payment of INR 50,000 to Kestrel.").isEmpty)
        #expect(found("We paid a total of INR 100,000 to Kestrel in March.").isEmpty)
        #expect(found("We paid a total of INR 60,000 to Kestrel in March.").count == 1)
        #expect(found("I approved one payment of INR 50,000 to Kestrel in March.", [pay(nil, "R1"), pay("2026-03-11", "R2")]).isEmpty)
        #expect(found("I approved one payment of INR 50,000 to Kestrel in April.").isEmpty)
        #expect(found("I approved one payment of INR 50,000 to Northwind in March.").isEmpty)
        #expect(found("I approved one payment of INR 50,000 to Kestrel in March.").count == 1)
        // The money records' own document saying it is not a pair with itself.
        #expect(F.moneyRecordFindings([F.Document(objectID: stmt.objectID, sourceVersionID: v, text: "One payment of INR 50,000 to Kestrel was made in March.")], movements: two).isEmpty)
    }

    @Test("The case-check screen states what the rules compare and what they do not")
    func coverageStated() {
        let text = F.ruleCoverage
        for word in ["₹", "lakh", "€", "money records", "dates", "ages", "Not compared", "different currencies", "does not show that the documents agree"] {
            #expect(text.contains(word), "\(word)")
        }
    }
}
