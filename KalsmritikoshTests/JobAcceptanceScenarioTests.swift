//
//  JobAcceptanceScenarioTests.swift
//  KalsmritikoshTests
//
//  Completion instructions 2026-10-29, B3 — every job counted as `executor` is checked against its
//  OWN written acceptance scenario (JobContracts.acceptance), not just a form that saves. For each
//  job: the draft its executor produces on a realistic case is asserted for the scenario's content
//  (disputed dates kept both ways, unassessed sources unassessed, hypotheses never findings,
//  currencies totalled separately, a replaced version flagged, …); the reviewer then records the
//  contract's columns with realistic values; completion is refused where the scenario forbids it;
//  the completed revision reopens unchanged; its export marks every reviewer entry and leaves rejected
//  rows out of the result. A job without a scenario here fails the suite — it cannot be counted.
//

import Foundation
import AppKit
import CoreText
import Testing
@testable import Kalsmritikosh

@Suite("Every executor job meets its acceptance scenario (B3)")
struct JobAcceptanceScenarioTests {

    static func day(_ s: String) -> Date { JobFamilyExecutorTests.day(s) }

    /// The realistic case: the two-document fixture, plus dated events (one fact with two dates), an
    /// expired passport, a policy inception and a loss, two equal separate payments, and a replaced
    /// version of the memo.
    static func evidence() -> JobEvidence {
        let (base, a, b) = JobFamilyExecutorTests.fixture()
        func r(_ d: StudioCaseDocument, _ q: String) -> StudioEvidenceRef { StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: q) }
        let f = base.facts
        let facts = StudioCaseFacts(caseTitle: "Case", parties: [], dates: [], amounts: [], identifiers: [], documents: f.documents,
            events: [StudioCaseEvent(date: day("2026-03-03"), title: "Payment approved by Asha Rao", refs: [r(a, "approved the payment")]),
                     StudioCaseEvent(date: day("2026-03-02"), title: "Payment approved by Asha Rao", refs: [r(b, "approved on 2 March")]),
                     StudioCaseEvent(date: day("2025-01-01"), title: "Policy inception", refs: [r(a, "policy incepted")]),
                     StudioCaseEvent(date: day("2026-02-14"), title: "Loss reported", refs: [r(b, "loss reported")])],
            allFacts: f.allFacts, named: f.named,
            statedAmounts: f.statedAmounts + [StudioCaseValue(value: "₹1,000", label: "amount", refs: [r(b, "a second payment of ₹1,000")])],
            statedDates: f.statedDates + [StudioCaseEvent(date: day("2026-01-05"), title: "The passport expired on January 5, 2026.", refs: [r(a, "passport expired")])])
        return JobEvidence(facts: facts, texts: base.texts, withheld: base.withheld, now: base.now,
                           versionHashes: [a.sourceVersionID!: String(repeating: "a", count: 64), b.sourceVersionID!: String(repeating: "b", count: 64)],
                           exports: [], batesPrefix: "ACME", replacedVersions: [a.sourceVersionID!])
    }

    /// What a reviewer records for each contract column — realistic, typed, never a placeholder.
    static func value(_ f: JobField, job: String, row: Int) -> String {
        switch f.kind {
        case .date: return "2026-06-1\(row % 10)"
        case .amount: return "1,000.00"
        case .currency: return "INR"
        case .choice(let options):
            let preferred: [String: String] = ["opportunity": "given", "cleared": "held", "verdict": "effective", "status": "in progress",
                                               "outcome": "inconclusive", "conclusion": "undecided", "current": "yes",
                                               "present": "present", "endorsement": "no", "duplicates": "kept separate — distinct payment",
                                               "reconciled": "statement balance", "classification": "payment", "method": "direct"]
            return preferred[f.key].flatMap { options.contains($0) ? $0 : nil } ?? options[0]
        case .text:
            let texts: [String: String] = [
                "owner": "Priya Nair (Compliance)", "linked": "Finding 2 — late approval", "evidence": "Re-sampled 20 payments in June: all approved in time",
                "rationale": "Author was present; consistent with the bank record", "reasons": "Consistent with the email of 3 March; no motive to misstate",
                "response": "Respondent says the delay was the vendor's", "allegation": "Payment approved without a second signature",
                "from": "HDFC 0042", "to": "ICICI 7781", "head": "Delay costs", "assumptions": "Delay ran 3 March to 1 July",
                "repository": "State Archives, Series 12", "policy": "POL-5521", "insurer": "Acme Mutual", "cover": "Fire and theft",
                "asset": "Flat 4B, Rose Court", "location": "Fireproof safe, home office", "access": "Owner and spouse",
                "questions": "Who approved INV-1? [memo.txt]", "topics": "Approval of INV-1", "claims": "That the invoice was checked twice",
                "trigger": "Delivery of goods", "rule": "Clause 9.2: 30 days from delivery", "party": "Vendor", "element": "Breach",
                "indicator": "Claim made 30 days after inception", "innocent": "Policyholder moved house that month",
                "error": "Wrong amount", "correction": "₹1,000 not ₹10,000", "reason": "Misread figure", "item": "Note 4",
                "result": "Nothing found in the 1890–1900 register", "effect": "The birth year stays unproven",
                "identifiers": "Name, parish, father's name", "relationship": "Daughter", "relative": "Asha Rao",
                "issues": "Approval", "annotation": "Signature is a later addition", "series": "Correspondence 2026",
                "provenance": "Received from the client on 1 May", "origin": "Company email server", "authorship": "Asha Rao", "bias": "Interested party",
                "statements": "Statement of 3 March", "documents": "memo.txt", "inconsistencies": "Two dates for the approval",
                "connection": "Paid sponsorship", "required": "“Ad” label", "instrument": "FTC Endorsement Guides, 16 CFR 255", "version": "2023 revision",
                "finalText": "Final cleared text, version 3", "recipient": "Bank's fraud team", "claim": "Breach of clause 9", "account": "Account A",
                "for": "memo.txt states the vendor sent the wrong invoice", "against": "email.eml does not mention the invoice",
                "calculation": "Sum of approved payments", "inputs": "memo.txt", "steps": "Collected payments; checked approvals",
                "point": "Who approved", "transcription": "As spoken", "codes": "APPROVAL", "period": "March 2026",
                "edge": "Asha Rao — approved — payment", "access log note": "Viewed 1 June", "action": "Add a second signature step",
                "date": "2026-06-01", "title": "Approval memo",
            ]
            return texts[f.key] ?? "\(f.label) — as checked against the source on 1 June 2026"
        }
    }

    typealias Check = (JobRun, JobEvidence) -> [String]

    static func flagged(_ r: JobRun, _ flag: String) -> Bool { r.content.rows.contains { $0.flags.contains(flag) } }
    static func allCited(_ r: JobRun) -> Bool { !r.content.rows.isEmpty && r.content.rows.allSatisfy { !$0.refs.isEmpty } }
    static func expect(_ ok: Bool, _ why: String) -> [String] { ok ? [] : [why] }

    /// Each executor job's acceptance scenario, asserted on its draft.
    static let scenarios: [String: Check] = {
        var m: [String: Check] = [:]
        // Chronologies: a fact with two dates appears twice marked disputed; every row cited.
        for j in ["inv.linkage", "law.fact-chronology", "hr.incident-timeline", "jrn.chronology", "ind.personal-chronology"] {
            m[j] = { r, _ in expect(r.content.rows.filter { $0.flags.contains("disputed date") }.count == 2, "disputed fact not shown both ways")
                + expect(allCited(r), "a row without a source") }
        }
        m["siu.loss-chronology"] = { r, _ in
            expect(r.content.rows.contains { $0.title == "Policy inception" && !$0.refs.isEmpty }
                   && r.content.rows.contains { $0.title == "Loss reported" && !$0.refs.isEmpty }, "inception and loss not both shown with sources") }
        m["law.deadlines"] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags.contains("unconfirmed") }, "a deadline shown as confirmed") }
        // Inventories.
        for j in ["res.corpus-catalogue", "res.metadata"] {
            m[j] = { r, _ in expect(flagged(r, "no date stated"), "missing or uncertain date not shown") }
        }
        for j in ["hr.evidence-register", "siu.prior-claims"] {
            m[j] = { r, _ in expect(allCited(r), "an item listed without its source") }
        }
        m["law.exhibit-binder"] = { r, e in
            let first = r.content.rows.first
            return expect(first?.title.hasPrefix("EX-001") == true, "exhibits not numbered")
                + expect(first?.refs.first?.sourceVersionID == e.facts.documents.first?.sourceVersionID, "an exhibit does not cite its exact version")
                + expect(flagged(r, "replaced by a newer version"), "a replaced version is not flagged")
        }
        for j in ["res.bibliography", "gen.originals"] {
            m[j] = { r, _ in expect(flagged(r, "citation metadata incomplete"), "an incomplete citation is not flagged") }
        }
        for j in ["ind.document-versions", "ind.insurance"] {
            m[j] = { r, _ in expect(r.content.rows.contains { $0.flags.contains("passed: 2026-01-05") }, "an expired document not shown as expired") }
        }
        m["ind.property"] = { r, e in expect(r.content.rows.count == e.facts.documents.count, "a mention created an ownership record") }
        m["ind.applications"] = { r, _ in expect(allCited(r), "a pack document without its source") }
        m["ind.document-vault"] = { r, e in
            let pre = JobFields.prefill(job: "ind.document-vault", rows: r.content.rows, evidence: e)
            return expect(pre.contains { $0.fields?["hash"] == String(repeating: "a", count: 64) }, "an original's hash does not match its stored bytes")
        }
        m["ind.reminders"] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.decision == nil }, "a computed date confirmed without the person") }
        // Assessments: never graded by the app.
        for j in ["inv.source-reliability", "law.source-desk", "siu.source-vetting", "jrn.source-reliability", "ind.doc-reliability",
                  "fa.doc-reliability", "hr.credibility", "res.source-criticism", "gen.source-analysis"] {
            m[j] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags.contains("not assessed") }, "a source shown as assessed by the app") }
        }
        // Matrices.
        for j in ["law.fact-evidence", "law.obligations", "siu.red-flags", "hr.allegations", "gen.evidence-notes"] {
            m[j] = { r, _ in expect(r.content.rows.contains { $0.flags.contains { $0.hasPrefix("conflicting value") } }, "a conflict was averaged away")
                + expect(r.content.rows.contains { $0.flags.contains("single source") }, "single-source support not flagged") }
        }
        // Statements.
        for j in ["jrn.quote-book", "jrn.transcript"] {
            m[j] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags == ["verbatim"] && !$0.refs.isEmpty }, "a quote not verbatim or not cited") }
        }
        for j in ["jrn.interview-plan", "hr.interview-prep"] {
            m[j] = { r, _ in expect(Set(r.content.rows.map(\.title)) == ["Asha Rao", "Vikram Rao"] && r.content.rows.allSatisfy { $0.flags.contains("not yet interviewed") },
                                    "the plan does not list every person to put the claims to") }
        }
        // Causation: a hypothesis, never a finding.
        for j in ["law.causation", "siu.causation", "jrn.causal", "ind.why", "res.causal", "fa.analysis", "gen.migration"] {
            m[j] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags == ["hypothesis — not a finding"] }, "a cause stated as a finding") }
        }
        // Money.
        m["law.damages"] = { r, _ in
            expect(r.content.rows.contains { $0.title.hasPrefix("Stated amounts in INR") }, "no per-currency total")
                + expect(r.content.rows.first { $0.title == "$2.75 million" }?.flags.contains("currency not stated — not totalled") == true, "an unsourced currency was totalled")
        }
        m["fa.funds-tracing"] = { r, _ in
            expect(r.content.rows.filter { $0.title == "₹1,000" }.count == 2, "two equal separate payments were merged") }
        // Disclosure.
        for j in ["ind.health-scope", "ind.secure-share", "hr.disclosure-review"] {
            m[j] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags.contains("not cleared — needs your review") }, "something cleared for disclosure automatically") }
        }
        m["jrn.data-desk"] = { r, e in expect(DataAnalysisExecutor.run(e).content == r.content, "re-running the analysis gave a different result") }
        m["jrn.publication"] = { r, _ in expect(r.content.rows.contains { $0.title.hasPrefix("Reply opportunity") }, "no reply request planned for an adverse claim") }
        m["jrn.publication-package"] = m["jrn.publication"]
        m["gen.same-person"] = { r, _ in expect(r.content.rows.first?.flags == ["undecided — kept separate"], "two same-name people merged without corroboration") }
        // Action registers: each action links to what it addresses (pre-filled), status open.
        for j in ["inv.capa-register", "law.remediation", "siu.recovery-actions", "fa.recovery", "hr.corrective-actions",
                  "jrn.correction-actions", "ind.fix-it", "gen.to-do", "res.errata", "jrn.correction-history"] {
            m[j] = { r, e in
                let pre = JobFields.prefill(job: j, rows: r.content.rows, evidence: e)
                let linkKey = JobFields.specs[j]?.contains { $0.key == "linked" } == true
                return expect(!pre.isEmpty, "no action rows")
                    + (linkKey ? expect(pre.allSatisfy { !($0.fields?["linked"] ?? "").isEmpty }, "an action not linked to its finding") : [])
                    + expect(r.content.rows.allSatisfy { $0.flags == ["open — no action recorded"] }, "an action shown as done by the app")
            }
        }
        // Reviews: every action starts unassessed (an ineffective one reopens — `ineffectiveReopens`).
        for j in JobExecutorKind.reviewedRegister.keys {
            m[j] = { r, _ in expect(!r.content.rows.isEmpty && r.content.rows.allSatisfy { $0.flags == ["effectiveness not assessed"] }, "effectiveness assumed") }
        }
        // Methods: the worksheet's run reopens unchanged — `JobResultWorkflowTests.methodRunsSaved`.
        for j in ["inv.methods", "res.methods", "jrn.methods", "ind.methods", "law.methods", "fa.methods", "gen.methods"] {
            m[j] = { r, _ in expect(r.content.rows.allSatisfy { $0.fields?["methodID"] != nil }, "a method row without its method") }
        }
        // Redaction: the file check — `producedFileRedaction`.
        m["law.redaction"] = { r, _ in expect(r.content.rows.allSatisfy { $0.fields?["check"] == "text-only snapshot" }, "a snapshot check not labelled text-only") }
        return m
    }()

    @Test("Every executor job has its acceptance scenario here")
    func everyJobHasAScenario() {
        let missing = JobExecutorKind.contractMet.subtracting(Self.scenarios.keys).sorted()
        #expect(missing.isEmpty, "jobs counted as executor without an acceptance scenario: \(missing)")
        for (job, why) in JobExecutorKind.reopened {
            #expect(JobContracts.contract(for: job)?.status == .preparation && !why.isEmpty, "\(job)")
        }
    }

    @Test("Each executor job: its draft meets the scenario; the reviewer's realistic entries complete it; it reopens unchanged; the export marks the entries and leaves rejected rows out",
          arguments: Array(JobExecutorKind.contractMet).sorted())
    func scenario(_ job: String) async throws {
        let kind = try #require(JobExecutorKind.assignments[job])
        let e = Self.evidence()
        let raw = try #require(JobFamilyExecutorTests.rows(for: job, kind: kind, e))
        let failures = (Self.scenarios[job]?(raw, e)) ?? ["no scenario"]
        #expect(failures.isEmpty, "\(job) — \(JobContracts.contract(for: job)?.acceptance ?? ""): \(failures)")
        guard raw.state == .draft, job != "law.redaction" else { return }   // redaction completes on a file check
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID()
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .uuid(UUID()), .text("Case"), .integer(1), .text("T"), .date(Date()), .date(Date())])
        let repo = JobResultRepository(database: db)
        let family = try #require(JobContracts.contract(for: job)?.family)
        try await repo.save(caseID: caseID, jobID: job, family: family, state: raw.state,
                            content: JobResultContent(rows: JobFields.prefill(job: job, rows: raw.content.rows, evidence: e), limitations: raw.content.limitations), actor: "T")
        let current = try #require(try await repo.latest(caseID: caseID, jobID: job))
        // The reviewer accepts every row but the last (when there is more than one) and records the columns.
        var rows = current.content.rows
        for i in rows.indices {
            // A row with no source is rejected (it could not be relied on); the last is rejected to
            // check that rejected rows stay out of the exported result.
            rows[i].decision = (rows.count > 1 && i == rows.count - 1) || rows[i].refs.isEmpty ? .rejected : .accepted
            var d = rows[i].fields ?? [:]
            for f in JobFields.specs[job] ?? [] where JobFields.missing(job: job, row: rows[i]).contains(f) || ((d[f.key] ?? "").isEmpty && f.required) {
                d[f.key] = Self.value(f, job: job, row: i)
            }
            rows[i].fields = d
            if rows[i].changedSourcedValue || rows[i].fields?["status"] == "done" { rows[i].note = "Checked against the source on 1 June" }
        }
        try await repo.saveReview(of: current, rows: rows, complete: true, note: "Reviewed every row against its passage", actor: "Reviewer")
        let done = try #require(try await repo.latest(caseID: caseID, jobID: job))
        #expect(done.state == .completed, "\(job) not completed")
        // Reopened from the ledger: the same rows, decisions and entries.
        let reopened = try #require(try await JobResultRepository(database: db).history(caseID: caseID, jobID: job).first)
        #expect(reopened.content.rows.map(\.fields) == done.content.rows.map(\.fields) && reopened.content.rows.map(\.decision) == done.content.rows.map(\.decision))
        let md = JobResultMarkdown.render(done, title: job)
        if let entry = done.content.rows.first(where: { $0.decision == .accepted && !($0.assertions ?? []).isEmpty }) {
            #expect(md.contains("[reviewer's entry"), "\(job): reviewer entries not marked (\(entry.assertions ?? []))")
        }
        if rows.count > 1, let last = rows.last {
            let result = md.components(separatedBy: "## Not included").first ?? md
            #expect(!result.contains("\n\(rows.count). ") && md.contains("## Not included") && md.contains(last.title),
                    "\(job): a rejected row was exported as part of the result")
        }
    }

    // MARK: - Scenario rules a completion must not break

    static func repoWith(_ job: String, rows: [JobResultRow]) async throws -> (JobResultRepository, JobResultRecord) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID()
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .uuid(UUID()), .text("Case"), .integer(1), .text("T"), .date(Date()), .date(Date())])
        let repo = JobResultRepository(database: db)
        try await repo.save(caseID: caseID, jobID: job, family: try #require(JobContracts.contract(for: job)?.family), state: .draft,
                            content: JobResultContent(rows: rows), actor: "T")
        return (repo, try #require(try await repo.latest(caseID: caseID, jobID: job)))
    }

    static func filled(_ job: String, _ row: JobResultRow, _ overrides: [String: String] = [:]) -> JobResultRow {
        var r = row; r.decision = .accepted
        var d = r.fields ?? [:]
        for f in JobFields.specs[job] ?? [] where (d[f.key] ?? "").isEmpty { d[f.key] = value(f, job: job, row: 0) }
        for (k, v) in overrides { d[k] = v }
        r.fields = d
        return r
    }

    @Test("Scenario rules: an action closed without a note, an allegation not yet put, a cleared story with an unrequested reply, a transfer to the same account, an unsourced register item — each refused")
    func scenarioRules() async throws {
        let e = Self.evidence()
        func refused(_ job: String, _ rows: [JobResultRow], _ fix: [JobResultRow]) async throws {
            // The generated result: the executor's rows as produced (no decision, no reviewer entries).
            let (repo, base) = try await Self.repoWith(job, rows: rows.map { var r = $0; r.decision = nil; r.fields = nil; r.note = nil; return r })
            await #expect(throws: JobResultReviewError.self, "\(job) completed against its scenario") {
                try await repo.saveReview(of: base, rows: rows, complete: true, note: "Reviewed", actor: "Reviewer")
            }
            try await repo.saveReview(of: base, rows: fix, complete: true, note: "Reviewed", actor: "Reviewer")
        }
        let action = JobFields.prefill(job: "inv.capa-register", rows: ActionExecutor.register(e).content.rows, evidence: e)[0]
        let closed = Self.filled("inv.capa-register", action, ["status": "done"])
        var closedWithNote = closed; closedWithNote.note = "Second signature now required; verified on 1 June"
        try await refused("inv.capa-register", [closed], [closedWithNote])
        let person = StatementExecutor.interviewPlan(e).content.rows[0]
        try await refused("hr.interview-prep", [Self.filled("hr.interview-prep", person, ["opportunity": "not yet"])],
                          [Self.filled("hr.interview-prep", person, ["opportunity": "given"])])
        let pub = PublicationExecutor.run(e).content.rows
        let cleared = pub.map { r -> JobResultRow in
            r.title.hasPrefix("Reply opportunity") ? { var x = r; x.decision = .rejected; return x }() : Self.filled("jrn.publication", r, ["cleared": "cleared"])
        }
        let held = pub.map { Self.filled("jrn.publication", $0, ["cleared": "held"]) }
        try await refused("jrn.publication", cleared, held)
        let pay = MoneyExecutor.run(e).content.rows.first { $0.title == "₹1,000" }!
        try await refused("fa.funds-tracing", [Self.filled("fa.funds-tracing", pay, ["from": "HDFC 0042", "to": "HDFC 0042"])],
                          [Self.filled("fa.funds-tracing", pay)])
        var unsourced = JobResultRow(title: "Laptop handed in on 2 March"); unsourced.manual = true
        let sourced = InventoryExecutor.run(e, style: .catalogue).content.rows[0]
        try await refused("hr.evidence-register", [Self.filled("hr.evidence-register", unsourced)],
                          [Self.filled("hr.evidence-register", sourced), { var r = unsourced; r.decision = .rejected; return r }()])
        let paid = Self.filled("hr.disclosure-review", DisclosureExecutor.run(e).content.rows[0], ["endorsement": "yes", "present": "absent"])
        var paidNoted = paid; paidNoted.note = "Add an “Ad” label at the start (16 CFR 255, 2023 revision)"
        try await refused("hr.disclosure-review", [paid], [paidNoted])
    }

    @Test("Redaction validation reads the produced file: a PDF leaking an identifier in its text or metadata fails; a clean file passes; a snapshot check cannot complete")
    func producedFileRedaction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terms = RedactionValidationExecutor.protectedTerms(Self.evidence())
        #expect(terms.contains("asha.rao@example.com"))
        func pdf(_ text: String, title: String) throws -> URL {
            let url = dir.appendingPathComponent("\(UUID().uuidString).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: title] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage(); ctx.closePDF()
            return url
        }
        let leakyText = try ProducedFileRedactionCheck.check(fileAt: try pdf("Contact asha.rao@example.com today", title: "Production"), protectedTerms: terms, ocr: false)
        #expect(leakyText.leaks.contains { $0.hasPrefix("text layer") } && !leakyText.passed && leakyText.sha256.count == 64)
        let leakyMeta = try ProducedFileRedactionCheck.check(fileAt: try pdf("Contact [REDACTED] today", title: "From asha.rao@example.com"), protectedTerms: terms, ocr: false)
        #expect(leakyMeta.leaks.contains { $0.hasPrefix("metadata") }, "\(leakyMeta.leaks)")
        let clean = try ProducedFileRedactionCheck.check(fileAt: try pdf("Contact [REDACTED] today", title: "Production"), protectedTerms: terms, ocr: false)
        #expect(clean.passed && clean.checked.contains("text layer") && clean.checked.contains("metadata"), "\(clean)")
        let txt = dir.appendingPathComponent("letter.txt")
        try Data("Phone [REDACTED]".utf8).write(to: txt)
        #expect(try ProducedFileRedactionCheck.check(fileAt: txt, protectedTerms: terms).checked == ["text"])
        // Completion: a snapshot-only check is refused; an accepted failed file check is refused; a clean file completes.
        let snapshot = RedactionValidationExecutor.run(JobEvidence(facts: Self.evidence().facts, texts: Self.evidence().texts,
                                                                   exports: [(title: "Snapshot", text: "Contact [REDACTED]")])).content.rows[0]
        #expect(snapshot.flags == ["text-only pre-check passed — not a check of the file"])
        var acceptedSnapshot = snapshot; acceptedSnapshot.decision = .accepted
        let fail = { var r = RedactionValidationExecutor.row(for: leakyText, terms: terms.count); r.decision = .accepted; return r }()
        let pass = { var r = RedactionValidationExecutor.row(for: clean, terms: terms.count); r.decision = .accepted; return r }()
        let (repo, base) = try await Self.repoWith("law.redaction", rows: [snapshot])
        for bad in [[acceptedSnapshot], [fail]] {
            await #expect(throws: JobResultReviewError.self) { try await repo.saveReview(of: base, rows: bad, complete: true, note: "Checked", actor: "Reviewer") }
        }
        try await repo.saveReview(of: base, rows: [{ var r = snapshot; r.decision = .rejected; return r }(), pass], complete: true, note: "Checked the produced file", actor: "Reviewer")
        let done = try #require(try await repo.history(caseID: base.caseID, jobID: "law.redaction").first)
        #expect(done.state == .completed && done.content.rows.last?.fields?["sha256"] == clean.sha256)
    }
}
