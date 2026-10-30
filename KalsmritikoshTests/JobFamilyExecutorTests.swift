//
//  JobFamilyExecutorTests.swift
//  KalsmritikoshTests
//
//  §3 — per-family assertions for the shared executors: each produces its result from the case's
//  own evidence with exact references, flags what a person must still decide, never states a
//  conclusion that is the person's, and blocks with a reason when there is nothing to work from.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Shared job executors — every result family")
struct JobFamilyExecutorTests {

    static func day(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }

    /// Two documents: a memo and an email that agree on a name and disagree on an invoice amount.
    static func fixture(now: Date = day("2026-06-01")) -> (JobEvidence, StudioCaseDocument, StudioCaseDocument) {
        let a = StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: "memo.txt", date: nil)
        let b = StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: "email.eml", date: nil)
        let memo = """
        Asha Rao approved the payment of ₹1,000 on March 3, 2026. The delay happened because the vendor sent the wrong invoice.
        Rao said “the invoice was checked twice.” Contact asha.rao@example.com or +91 98765 43210. The renewal is due on July 1, 2026.
        """
        let email = "Vikram Rao wrote that Asha Rao signed the contract. The invoice total was $2.75 million."
        func r(_ d: StudioCaseDocument, _ q: String) -> StudioEvidenceRef { StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: q) }
        let facts = StudioCaseFacts(caseTitle: "Case", parties: [], dates: [], amounts: [], identifiers: [],
            documents: [a, b], events: [],
            allFacts: [StudioCaseValue(value: "INV-1", label: "invoicenumber", refs: [r(a, "INV-1")]),
                       StudioCaseValue(value: "INV-2", label: "invoicenumber", refs: [r(b, "INV-2")])],
            named: [StudioCaseValue(value: "Asha Rao", label: "person", refs: [r(a, "Asha Rao approved")]),
                    StudioCaseValue(value: "Vikram Rao", label: "person", refs: [r(b, "Vikram Rao wrote")])],
            statedAmounts: [StudioCaseValue(value: "₹1,000", label: "amount", refs: [r(a, "the payment of ₹1,000")]),
                            StudioCaseValue(value: "$2.75 million", label: "amount", refs: [r(b, "The invoice total was $2.75 million.")])],
            statedDates: [StudioCaseEvent(date: day("2026-03-03"), title: "Asha Rao approved the payment of ₹1,000 on March 3, 2026.", refs: [r(a, "March 3, 2026")]),
                          StudioCaseEvent(date: day("2026-07-01"), title: "The renewal is due on July 1, 2026.", refs: [r(a, "July 1, 2026")])])
        return (JobEvidence(facts: facts, texts: [a.objectID: memo, b.objectID: email], withheld: 1, now: now), a, b)
    }

    static let empty = JobEvidence(facts: .empty)

    @Test("Every evidence executor blocks with a reason on an empty case — never an empty success")
    func blockedOnEmpty() {
        for kind in Set(JobExecutorKind.assignments.values) {
            guard let r = JobExecutorKind.run(kind, Self.empty) else { continue }   // review/methods need the service
            #expect(r.state == .blocked, "\(kind) did not block on an empty case")
            #expect(r.content.rows.isEmpty && !r.content.limitations.isEmpty, "\(kind) blocked without a reason")
        }
    }

    @Test("Every assigned job has a contract of status executor in its declared family")
    func assignmentsMatchContracts() {
        for (job, _) in JobExecutorKind.assignments {
            let status = JobContracts.contract(for: job)?.status
            #expect(status == (JobExecutorKind.contractMet.contains(job) ? .executor : .preparation), "\(job)")
        }
        for (review, register) in JobExecutorKind.reviewedRegister {
            #expect(JobExecutorKind.assignments[review] == .actionReview && JobExecutorKind.assignments[register] == .actionRegister)
        }
    }

    @Test("Inventory: every document listed with its references; exhibits numbered; incomplete citations flagged; withheld counted")
    func inventory() {
        let (e, a, _) = Self.fixture()
        let cat = InventoryExecutor.run(e, style: .catalogue)
        #expect(cat.state == .draft && cat.content.rows.count == 2)
        #expect(cat.content.rows.allSatisfy { !$0.refs.isEmpty })
        #expect(cat.content.rows.first { $0.title == "email.eml" }?.flags.contains("no date stated") == true)
        #expect(cat.content.limitations.contains { $0.contains("1 case source") })
        let ex = InventoryExecutor.run(e, style: .exhibit)
        #expect(ex.content.rows.map(\.title).first?.hasPrefix("EX-001") == true)
        #expect(ex.content.rows.first?.refs.first?.sourceVersionID == a.sourceVersionID, "an exhibit cites the exact version")
        let cit = InventoryExecutor.run(e, style: .citation)
        #expect(cit.content.rows.contains { $0.flags.contains("citation metadata incomplete") })
        let rec = InventoryExecutor.run(e, style: .records)
        #expect(rec.content.rows.first { $0.title == "memo.txt" }?.flags.contains("upcoming: 2026-07-01") == true)
        let rem = InventoryExecutor.reminders(e)
        #expect(rem.content.rows.map(\.flags) == [["passed"], ["upcoming"]])
    }

    @Test("Reliability: corroboration counted, conflicts named, every source 'not assessed' — the grade is the person's")
    func reliability() {
        let (e, _, _) = Self.fixture()
        let r = ReliabilityExecutor.run(e)
        #expect(r.content.rows.count == 2 && r.content.rows.allSatisfy { $0.flags.contains("not assessed") })
        #expect(r.content.rows.allSatisfy { $0.flags.contains("conflict on invoicenumber") })
        #expect(r.content.rows.first { $0.title == "email.eml" }?.detail?.contains("of") == true)
        #expect(!r.content.rows.contains { ($0.detail ?? "").localizedCaseInsensitiveContains("reliable") })
    }

    @Test("Issue matrix: both values of a conflicting fact kept and flagged; single-source flagged")
    func issueMatrix() {
        let (e, _, _) = Self.fixture()
        let r = IssueMatrixExecutor.run(e)
        let inv = r.content.rows.filter { $0.title.hasPrefix("invoicenumber") }
        #expect(inv.count == 2 && inv.allSatisfy { $0.flags.contains { $0.hasPrefix("conflicting value") } })
        #expect(inv.allSatisfy { $0.flags.contains("single source") })
        #expect(r.content.nextActions.first?.contains("differently") == true)
    }

    @Test("Statements: quotes verbatim with speaker; interview plan per named person, not yet interviewed")
    func statements() {
        let (e, _, _) = Self.fixture()
        let q = StatementExecutor.quotes(e)
        #expect(q.content.rows.contains { $0.title.contains("“the invoice was checked twice.”") })
        #expect(q.content.rows.allSatisfy { $0.flags == ["verbatim"] && !$0.refs.isEmpty })
        let plan = StatementExecutor.interviewPlan(e)
        #expect(Set(plan.content.rows.map(\.title)) == ["Asha Rao", "Vikram Rao"])
        #expect(plan.content.rows.allSatisfy { $0.flags.contains("not yet interviewed") })
    }

    @Test("Causation: a causal sentence is a hypothesis, never a finding; none → blocked as inconclusive")
    func causation() {
        let (e, _, _) = Self.fixture()
        let r = CausationExecutor.run(e)
        #expect(r.content.rows.count == 1 && r.content.rows[0].title.contains("because"))
        #expect(r.content.rows[0].flags == ["hypothesis — not a finding"])
        #expect(r.content.nextActions.contains { $0.contains("alternative") })
    }

    @Test("Money: totals per stated currency only; '$2.75 million' and bare '$' left out of every total")
    func money() {
        let (e, _, _) = Self.fixture()
        let r = MoneyExecutor.run(e)
        #expect(r.content.rows.contains { $0.title == "Stated amounts in INR: 1,000.00 distinct" })
        let million = r.content.rows.first { $0.title == "$2.75 million" }
        #expect(million?.flags.contains("currency not stated — not totalled") == true)
        #expect(million?.flags.contains("not one plain figure — not totalled") == true)
        #expect(!r.content.rows.contains { $0.title.contains("USD") })
        #expect(r.content.limitations.contains { $0.contains("not evidence of loss") })
    }

    @Test("Disclosure: identifiers found by pattern; nothing cleared automatically; withheld sources outside the package")
    func disclosure() {
        let (e, _, _) = Self.fixture()
        let r = DisclosureExecutor.run(e)
        #expect(r.content.rows.allSatisfy { $0.flags.contains("not cleared — needs your review") })
        let memo = r.content.rows.first { $0.title == "memo.txt" }
        #expect(memo?.flags.contains("redaction candidate: 1 email address(s)") == true)
        #expect(memo?.flags.contains { $0.hasPrefix("redaction candidate:") && $0.contains("phone") } == true)
        #expect(r.content.limitations.first?.contains("not part of any disclosure") == true)
    }

    @Test("Data table, publication, deadlines, same-person, actions")
    func others() {
        let (e, _, _) = Self.fixture()
        #expect(DataTableExecutor.run(e).content.rows.contains { $0.title == "amount = ₹1,000" && $0.detail == "memo.txt" })
        let pub = PublicationExecutor.run(e)
        #expect(pub.content.rows.contains { $0.flags.contains("single-sourced — needs a second source") })
        #expect(pub.content.rows.contains { $0.title == "Reply opportunity: Vikram Rao" })
        let dl = DeadlineExecutor.run(e)
        #expect(dl.content.rows.count == 1 && dl.content.rows[0].flags == ["unconfirmed", "upcoming"])
        let same = IdentityCandidateExecutor.run(e)
        #expect(same.content.rows.map(\.title) == ["Asha Rao / Vikram Rao"] && same.content.rows[0].flags == ["undecided — kept separate"])
        let reg = ActionExecutor.register(e)
        #expect(reg.content.rows.contains { $0.title.hasPrefix("Resolve conflicting fact") })
        #expect(reg.content.rows.allSatisfy { $0.flags == ["open — no action recorded"] })
        #expect(ActionExecutor.review(register: nil).state == .blocked)
        let record = JobResultRecord(id: UUID(), caseID: UUID(), jobID: "inv.capa-register", family: "actionEffectivenessClosure",
                                     state: .draft, content: reg.content, createdBy: "Tester", createdAt: Self.day("2026-06-01"))
        let review = ActionExecutor.review(register: record)
        #expect(review.state == .draft && review.content.rows.count == reg.content.rows.count)
        #expect(review.content.rows.allSatisfy { $0.flags == ["effectiveness not assessed"] })
    }

    /// The value a person would record for a field (the first allowed choice, a date, or text).
    static func personValue(_ f: JobField) -> String {
        switch f.kind {
        case .choice(let options): return options[0]
        case .date: return "2026-06-01"
        case .text: return "recorded by the reviewer"
        case .amount: return "1,250.00"
        case .currency: return "USD"
        }
    }

    static func rows(for job: String, kind: JobExecutorKind, _ e: JobEvidence) -> JobRun? {
        switch kind {
        case .actionReview:
            let reg = ActionExecutor.register(e)
            let record = JobResultRecord(id: UUID(), caseID: UUID(), jobID: "x", family: "actionEffectivenessClosure",
                                         state: .draft, content: reg.content, createdBy: "T", createdAt: Date())
            return ActionExecutor.review(register: record)
        case .methodReadiness:
            return (.draft, JobResultContent(rows: [JobResultRow(title: "Five Whys (v1)", flags: ["not run"], fields: ["methodID": "m"])]))
        case .redactionValidation:
            let withExport = JobEvidence(facts: e.facts, texts: e.texts, exports: [(title: "Production", text: "redacted text")])
            return JobExecutorKind.run(kind, withExport)
        default:
            return JobExecutorKind.run(kind, e)
        }
    }

    // The per-job acceptance check is `JobAcceptanceScenarioTests` (B3): each job against its own
    // written acceptance scenario, with realistic reviewer entries.

    @Test("Pre-fill states what the ledger knows: hashes, exhibit and Bates numbers, amounts and currencies")
    func prefillFromLedger() {
        let (base, a, _) = Self.fixture()
        let e = JobEvidence(facts: base.facts, texts: base.texts, versionHashes: [a.sourceVersionID!: String(repeating: "a", count: 64)], batesPrefix: "ACME")
        let exhibits = JobFields.prefill(job: "law.exhibit-binder", rows: InventoryExecutor.run(e, style: .exhibit).content.rows, evidence: e)
        #expect(exhibits[0].fields?["exhibit"] == "EX-001" && exhibits[1].fields?["bates"] == "ACME-000002")
        #expect(exhibits[0].fields?["version"] == a.sourceVersionID?.uuidString)
        let vault = JobFields.prefill(job: "ind.document-vault", rows: InventoryExecutor.run(e, style: .records).content.rows, evidence: e)
        #expect(vault.first { $0.title == "memo.txt" }?.fields?["hash"] == String(repeating: "a", count: 64))
        let money = JobFields.prefill(job: "fa.funds-tracing", rows: MoneyExecutor.run(e).content.rows, evidence: e)
        let rupees = money.first { $0.title == "₹1,000" }
        #expect(rupees?.fields?["amount"] == "1,000.00" && rupees?.fields?["currency"] == "INR")
        #expect(money.first { $0.title == "$2.75 million" }?.fields?["currency"] == nil, "an unstated currency is never filled in")
    }

    @Test("Data analysis is computed and reproducible; a snapshot redaction check is labelled text-only")
    func computedResults() {
        let (e, _, _) = Self.fixture()
        let a1 = DataAnalysisExecutor.run(e), a2 = DataAnalysisExecutor.run(e)
        #expect(a1.content == a2.content, "the same sources give the same analysis")
        #expect(a1.content.rows.contains { $0.title.hasPrefix("amount:") && ($0.detail ?? "").contains("INR 1,000.00") })
        #expect(a1.content.limitations.contains { $0.hasPrefix("Query:") })
        #expect(RedactionValidationExecutor.run(Self.empty).state == .blocked, "no documents, nothing to protect")
        let produced = JobEvidence(facts: e.facts, texts: e.texts, exports: [
            (title: "Clean production", text: "Contact [REDACTED] or [REDACTED]."),
            (title: "Leaky production", text: "Contact asha.rao@exa<b>mple.com</b> please."),
        ])
        let r = RedactionValidationExecutor.run(produced)
        #expect(r.content.rows.first { $0.title == "Clean production" }?.flags == ["text-only pre-check passed — not a check of the file"])
        #expect(r.content.rows.first { $0.title == "Leaky production" }?.flags == ["redaction failed"])
    }

    @Test("An action reviewed as not effective reopens it in its register")
    func ineffectiveReopens() async throws {
        let (e, _, _) = Self.fixture()
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID()
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .uuid(UUID()), .text("Case"), .integer(1), .text("T"), .date(Date()), .date(Date())])
        let repo = JobResultRepository(database: db)
        let reg = ActionExecutor.register(e)
        try await repo.save(caseID: caseID, jobID: "inv.capa-register", family: .actionEffectivenessClosure, state: .draft,
                            content: JobResultContent(rows: JobFields.prefill(job: "inv.capa-register", rows: reg.content.rows, evidence: e)), actor: "T")
        let register = try #require(try await repo.latest(caseID: caseID, jobID: "inv.capa-register"))
        let review = ActionExecutor.review(register: register)
        try await repo.save(caseID: caseID, jobID: "inv.effectiveness-review", family: .actionEffectivenessClosure, state: .draft, content: review.content, actor: "T")
        let current = try #require(try await repo.latest(caseID: caseID, jobID: "inv.effectiveness-review"))
        let decided = current.content.rows.enumerated().map { i, r -> JobResultRow in
            var r = r; r.decision = .accepted
            r.fields = ["evidence": "re-checked", "verdict": i == 0 ? "not effective" : "effective"]; return r
        }
        try await repo.saveReview(of: current, rows: decided, complete: true, note: "Reviewed", actor: "Reviewer")
        let reopened = try #require(try await repo.latest(caseID: caseID, jobID: "inv.capa-register"))
        #expect(reopened.id != register.id && reopened.content.rows[0].fields?["status"] == "reopened")
    }
}
