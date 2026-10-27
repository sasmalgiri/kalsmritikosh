//
//  ForensicEngagementTests.swift
//  KalsmritikoshTests
//
//  Persona studio #4 — the forensic expert report must satisfy the FRCP
//  26(a)(2)(B)/Daubert disciplines: named method (indirect justified), sourced
//  schedule, findings distinct from opinion, certainty declared.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Forensic accounting studio")
struct ForensicEngagementTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stage gates enforce the Daubert disciplines")
    func stages() {
        var f = ForensicEngagement(title: "x", now: t0)
        #expect(ForensicEngagement.Stage.allCases.map(\.title) ==
                ["Engagement", "Materials", "Method", "Tracing schedule", "Findings & opinion"])
        // Method: an INDIRECT method requires justification; a direct one doesn't.
        f.methodID = "indirect.networth"
        #expect(!f.isComplete(.method))
        f.methodJustification = "Ledgers destroyed; direct tracing impossible."
        #expect(f.isComplete(.method))
        f.methodID = "direct.specific"; f.methodJustification = ""
        #expect(f.isComplete(.method))
        // Schedule rows must carry a source document.
        var t = FATransaction(); t.date = "2026-01-01"; t.descriptionText = "wire"; t.amount = "100"; t.currency = "USD"
        f.schedule = [t]
        #expect(!f.isComplete(.schedule))
        t.sourceDoc = "stmt.pdf p.1"; f.schedule = [t]
        #expect(f.isComplete(.schedule))
        // Opinion requires findings + text + the certainty declaration.
        f.findings = ["fact"]; f.opinion = "opinion"
        #expect(!f.isComplete(.opinion))
        f.certaintyDeclared = true
        #expect(f.isComplete(.opinion))
    }

    @Test("The report is the 26(a)(2)(B) hardcopy, sections in order, with the schedule total")
    func hardcopy() {
        let md = FAReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        #expect(md.contains("Fed. R. Civ. P. 26(a)(2)(B)"))
        let sections = ["1. Engagement & scope", "2. Qualifications", "3. Materials relied upon",
                        "4. Methodology", "5. Tracing schedule", "6. Findings of fact", "7. Opinion", "8. Limitations"]
        var last = md.startIndex
        for s in sections {
            let r = md.range(of: s, range: last..<md.endIndex)
            #expect(r != nil, "missing or out-of-order section: \(s)")
            if let r { last = r.upperBound }
        }
        // Named method + discipline; sourced schedule columns; computed total (18400+18400+30000).
        #expect(md.contains("Specific identification (direct tracing)"))
        #expect(md.contains("state the method used"))
        #expect(md.contains("| # | Date | Description | Payer | Payee | Amount | Account | Source document |"))
        #expect(md.contains("**Schedule total (USD):** gross movements 66,800.00; returned (refunds, reversals) 0.00; **net 66,800.00**"))
        // Findings vs opinion separation + certainty.
        #expect(md.contains("factual observations; the opinion below"))
        #expect(md.contains("reasonable degree of professional certainty"))
        // Limitations state what was NOT produced and what is NOT opined.
        #expect(md.contains("was not produced"))
        #expect(md.contains("No opinion is offered on intent"))
    }

    // MARK: - Final brief §3.4 — money

    func row(_ date: String, _ amount: String, _ kind: FAKind?, account: String = "#2210", payee: String = "Vendor", ref: String? = nil, src: String = "stmt.pdf") -> FATransaction {
        var t = FATransaction(); t.date = date; t.descriptionText = "x"; t.amount = amount; t.kind = kind
        t.account = account; t.payer = "Acme"; t.payee = payee; t.reference = ref; t.sourceDoc = src
        return t
    }

    @Test("Two ₹1,000 payments and a duplicate copy are ₹2,000; a ₹1,000 reversal makes the net ₹1,000, gross kept")
    func equalAmountsDuplicatesReversal() {
        var f = ForensicEngagement(title: "x", now: t0)
        f.schedule = [row("2026-01-05", "₹1,000", .payment, ref: "UTR1"),
                      row("2026-01-09", "₹1,000", .payment, ref: "UTR2"),
                      row("2026-01-09", "₹1,000", .payment, ref: "UTR2", src: "stmt-copy.pdf")]   // the same payment in another document
        var s = f.summary
        #expect(s.byCurrency["INR"]?.gross == 2000 && s.byCurrency["INR"]?.net == 2000)
        #expect(s.duplicateCopies.count == 1)
        f.schedule.append(row("2026-01-12", "₹1,000", .reversal, ref: "REV-UTR2"))
        s = f.summary
        #expect(s.byCurrency["INR"]?.gross == 2000)
        #expect(s.byCurrency["INR"]?.returned == 1000)
        #expect(s.byCurrency["INR"]?.net == 1000)
        // The accountant can say two look-alike rows are separate payments.
        f.schedule[2].confirmedDistinct = true
        #expect(f.summary.byCurrency["INR"]?.gross == 3000)
    }

    @Test("Mentions are candidates until classified; non-movements and other currencies stay out of a total")
    func candidatesAndCurrencies() {
        var f = ForensicEngagement(title: "x", now: t0)
        f.schedule = [row("2026-01-05", "USD 500", .payment), row("2026-01-06", "€200", .fee),
                      row("2026-01-07", "USD 9,999", .invoice), row("2026-01-08", "USD 750", .unclassified)]
        let s = f.summary
        #expect(s.byCurrency["USD"]?.gross == 500)
        #expect(s.byCurrency["EUR"]?.gross == 200)
        #expect(s.notMovements.count == 1 && s.unclassified.count == 1)
        #expect(!f.isComplete(.schedule))   // an unclassified row blocks the schedule stage
        let md = FAReportRenderer.markdown(f, generatedAt: t0)
        #expect(md.contains("Currencies are totalled separately"))
        #expect(md.contains("not yet classified as movements: row 4"))
        // Exact decimals: 0.1 + 0.2 is 0.3.
        var g = ForensicEngagement(title: "y", now: t0)
        g.schedule = [row("2026-01-01", "USD 0.10", .payment, ref: "a"), row("2026-01-02", "USD 0.20", .payment, ref: "b")]
        #expect(g.summary.byCurrency["USD"]?.gross == Decimal(string: "0.30"))
        #expect(FAMoney.currency(of: "1,000 FOR services") == "")
        #expect(FAMoney.value(of: "(1,250.50)") == Decimal(string: "-1250.5"))
    }

    @Test("A second prefill adds a different passage with the same amount and never re-adds the same one; prefilled rows are candidates")
    func prefillByPassage() {
        let v1 = UUID(), v2 = UUID()
        let a1 = StudioCaseValue(value: "₹1,000", label: "amount", refs: [StudioEvidenceRef(sourceVersionID: v1, objectID: UUID(), quote: "paid ₹1,000 on 5 Jan")])
        let a2 = StudioCaseValue(value: "₹1,000", label: "amount", refs: [StudioEvidenceRef(sourceVersionID: v2, objectID: UUID(), quote: "paid ₹1,000 on 9 Jan")])
        var f = ForensicEngagement(title: "x", now: t0)
        f.prefill(from: StudioCaseFacts(caseTitle: "c", parties: [], dates: [], amounts: [a1], identifiers: [], documents: [], events: [], allFacts: []))
        f.prefill(from: StudioCaseFacts(caseTitle: "c", parties: [], dates: [], amounts: [a1, a2], identifiers: [], documents: [], events: [], allFacts: []))
        #expect(f.schedule.count == 2)
        #expect(f.schedule.allSatisfy { f.kind(of: $0) == .unclassified && $0.effectiveCurrency == "INR" })
        #expect(f.summary.byCurrency.isEmpty)
    }

    @Test("Statements reconcile against the schedule; a missing month is shown")
    func reconciliation() {
        var f = ForensicEngagement(title: "x", now: t0)
        f.schedule = [row("2026-01-05", "₹1,000", .payment, ref: "1"), row("2026-01-20", "₹300", .receipt, ref: "2")]
        var jan = FAReconciliation(); jan.account = "#2210"; jan.periodStart = "2026-01-01"; jan.periodEnd = "2026-01-31"; jan.opening = "₹5,000"; jan.closing = "₹4,300"
        var mar = FAReconciliation(); mar.account = "#2210"; mar.periodStart = "2026-03-01"; mar.periodEnd = "2026-03-31"; mar.opening = "₹4,300"; mar.closing = "₹4,000"
        f.reconciliations = [jan, mar]
        let r = f.reconcile()
        #expect(r[0].expectedClosing == 4300 && r[0].difference == 0)
        #expect(r[1].difference == -300)
        #expect(f.missingPeriods == ["#2210: 2026-02-01 – 2026-02-28"])
        let md = FAReportRenderer.markdown(f, generatedAt: t0)
        #expect(md.contains("reconciles") && md.contains("unexplained") && md.contains("Periods with no statement"))
    }

    @Test("Review R6: ISO codes beat '$'; a bare '$' is not USD; decimal commas; magnitude words refused; reconciliation by exact account and currency")
    func currencyAndReconciliationSafety() {
        #expect(FAMoney.currency(of: "CAD $1,000") == "CAD")
        #expect(FAMoney.currency(of: "C$1,000") == "CAD" && FAMoney.currency(of: "US$1,000") == "USD")
        #expect(FAMoney.currency(of: "$1,000") == "" && FAMoney.currencyIsAmbiguous("$1,000"))
        #expect(FAMoney.value(of: "1.234,56 EUR") == Decimal(string: "1234.56"))
        #expect(FAMoney.value(of: "1,234.56") == Decimal(string: "1234.56"))
        #expect(FAMoney.value(of: "12,5") == Decimal(string: "12.5"))
        #expect(FAMoney.value(of: "12,34,567") == 1234567)               // Indian grouping
        #expect(FAMoney.value(of: "₹1,000/-") == 1000)
        #expect(FAMoney.value(of: "1.5 million") == nil && FAMoney.value(of: "2 lakh") == nil && FAMoney.value(of: "5k") == nil)
        #expect(FAMoney.value(of: "1.234") == nil)                       // English 1.234 or European 1234: ambiguous
        // INR and USD movements in one account: only the statement's currency counts; the other is flagged.
        var f = ForensicEngagement(title: "x", now: t0)
        f.schedule = [row("2026-01-05", "₹1,000", .payment, ref: "1"), row("2026-01-06", "USD 1,000", .payment, ref: "2")]
        var jan = FAReconciliation(); jan.account = "#2210"; jan.periodStart = "2026-01-01"; jan.periodEnd = "2026-01-31"
        jan.opening = "₹5,000"; jan.closing = "₹4,000"
        f.reconciliations = [jan]
        var r = f.reconcile()[0]
        #expect(r.expectedClosing == 4000 && r.unresolved == ["1 movement(s) of this account are in another currency"] && r.difference == nil)
        // A blank account on a movement, or on the statement, cannot be placed.
        f.schedule = [row("2026-01-05", "₹1,000", .payment, account: "", ref: "1")]
        r = f.reconcile()[0]
        #expect(r.unresolved.contains("1 movement(s) in this period name no account"))
        jan.account = ""; f.reconciliations = [jan]
        #expect(f.reconcile()[0].unresolved.contains("the statement names no account"))
        // An account is matched exactly, not as a substring of a payee ("#22" is not "#2210").
        f.schedule = [row("2026-01-05", "₹1,000", .payment, account: "#2210", ref: "1")]
        jan.account = "#22"; f.reconciliations = [jan]
        #expect(f.reconcile()[0].expectedClosing == 5000)
        // Two same-value payments with no reference are both counted, and flagged.
        var g = ForensicEngagement(title: "y", now: t0)
        g.schedule = [row("2026-01-05", "₹1,000", .payment), row("2026-01-05", "₹1,000", .payment)]
        #expect(g.summary.byCurrency["INR"]?.gross == 2000 && g.summary.possibleDuplicates.count == 1 && g.summary.duplicateCopies.isEmpty)
    }

    @Test("A schedule saved before classification still opens and totals its hand-entered rows")
    func legacyRows() throws {
        let legacy = ##"{"id":"6F1A2D3E-0000-4000-8000-000000000001","date":"2026-01-01","descriptionText":"wire","payer":"A","payee":"B","amount":"$100","account":"#1","sourceDoc":"s.pdf"}"##
        let t = try JSONDecoder().decode(FATransaction.self, from: Data(legacy.utf8))
        var f = ForensicEngagement(title: "x", now: t0); f.schedule = [t]
        // "$100" does not say which dollar: counted under "currency not stated", and the schedule
        // cannot complete until it is stated (review R6).
        #expect(f.kind(of: t) == .payment && f.summary.byCurrency[""]?.gross == 100)
        #expect(f.summary.currencyUnstated == [t.id] && !f.isComplete(.schedule))
    }

    @Test("A whole engagement survives a JSON round-trip")
    func codable() throws {
        let original = [ForensicEngagement.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([ForensicEngagement].self, from: data) == original)
    }
}
