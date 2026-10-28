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
        #expect(r.content.rows.contains { $0.title == "Stated amounts in INR: 1,000.00" })
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

    /// A2 — the acceptance check for every job whose contract the executor meets: on the fixture case
    /// it produces a reviewable draft whose rows each cite a source, the person can decide each row,
    /// and the completed revision is saved (the contract's human step).
    @Test("Every contract-met job: a sourced draft the person can decide and complete", arguments: Array(JobExecutorKind.contractMet).sorted())
    func contractMetAcceptance(_ job: String) async throws {
        let kind = try #require(JobExecutorKind.assignments[job])
        let (e, _, _) = Self.fixture()
        let run = try #require(JobExecutorKind.run(kind, e))
        #expect(run.state == .draft, "\(job) did not produce a draft on the fixture")
        #expect(!run.content.rows.isEmpty && run.content.rows.allSatisfy { !$0.refs.isEmpty }, "\(job): every row cites its source")
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID()
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .uuid(UUID()), .text("Case"), .integer(1), .text("T"), .date(Date()), .date(Date())])
        let repo = JobResultRepository(database: db)
        let family = try #require(JobContracts.contract(for: job)?.family)
        try await repo.save(caseID: caseID, jobID: job, family: family, state: run.state, content: run.content, actor: "T")
        let current = try #require(try await repo.latest(caseID: caseID, jobID: job))
        let decided = current.content.rows.map { r -> JobResultRow in var r = r; r.decision = .accepted; r.note = "checked"; return r }
        try await repo.saveReview(of: current, rows: decided, complete: true, note: "Reviewed against the sources", actor: "Reviewer")
        let done = try #require(try await repo.latest(caseID: caseID, jobID: job))
        #expect(done.state == .completed && done.content.review?.by == "Reviewer" && done.content.rows.allSatisfy { $0.decision == .accepted })
    }
}
