//
//  CaseInvestigationJourneyTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (QA-17, §D.3): the thin AI-off journey through the production services, with no model and no
//  network — a point → an alternative explanation → a distinguishing check → an editable local query → its receipt →
//  a child action → a reviewed result → a revised brief, with the first brief still readable. (The money part of the pass
//  condition — two real debits kept apart from the refund, every counted entry opened — is SmartMapS7MoneyTests.)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("AI-off journey — point to revised brief", .serialized)
struct CaseInvestigationJourneyTests {

    @Test("Question → alternative → check → query and receipt → child action → reviewed result → revised brief, AI off")
    func journey() async throws {
        let f = try await CaseFileTests.fixture(title: "Was Kestrel Supplies paid twice for invoice INV-104?")
        let c = f.caseID
        let stmt = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "bank-statement-3391.txt", text:
            "Statement 3391. 5 March 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77120. 12 March 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77985. 19 March 2026: refund INR 50,000 from Kestrel Supplies.")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "witness-meera.txt", text:
            "Meera Shah said Kestrel Supplies was paid once for the March invoice.")

        // 1. The point under investigation, as a question of the case.
        let question = try await f.file.addAllegation(caseID: c, text: "Kestrel Supplies was paid INR 50,000 twice for invoice INV-104", actor: "Ada")
        let qNode = CaseMapNodeID(caseID: c, kind: .allegation, id: question)

        // 2. An alternative explanation with its line of inquiry (what would tell it apart).
        let alt = UUID()
        try await f.db.exec("""
            INSERT INTO investigation_hypotheses (id, case_id, kind, statement, status, revision, actor, created_at, updated_at)
            VALUES (?,?,'hypothesis','The second debit was a duplicate that the refund reversed','proposed',1,'Ada',1,1);
            """, [.uuid(alt), .uuid(c)])
        _ = try await f.file.recordInquiryLine(caseID: c, hypothesisID: alt, predictions: "A refund of the same amount follows the second debit",
                                               discriminator: "The refund's reference against KS-77985", assumptions: "The statement is complete for March",
                                               methods: ["com.kalsmritikosh.method.transaction-flow"], actor: "Ada")

        // 3. What hasn't been considered, and the distinguishing check, from the case's own records (AI off).
        let snapshot = try #require(try await f.svc.snapshot(caseID: c, custody: [CustodyManifestEntry(sourceVersionID: stmt.version, contentHash: nil, custodyEvents: [])]))
        let hypotheses = try await InvestigationAnalysisRepository(database: f.db).hypotheses(caseID: c)
        let input = CaseMethodReviewInput.from(question: "Was Kestrel paid twice?", snapshot: snapshot, coverage: nil, openContradictions: 0,
                                               money: try await f.file.moneyLedger(caseID: c), hypotheses: hypotheses, requests: [], runs: [], now: Date())
        let review = CaseMethodReview.assess(methods: CaseMethodReviewMethod.registered, input: input)
        #expect(review.accountsFor(CaseMethodReviewMethod.registered) && !review.shortlist.isEmpty)

        // 4. Check this claim: the editable local queries, run by the case search with its receipt.
        let plan = CaseClaimCheck.plan(claim: "Kestrel Supplies was paid INR 50,000 twice for invoice INV-104")
        let search = CaseSearchService(sources: .live(database: f.db))
        let options = CaseSearchOptions(timeZoneID: "UTC")
        let supporting = try #require(await search.run(caseID: c, text: plan.supporting, options: options).run, "\(plan.supporting)")
        #expect(supporting.hits.map(\.name).contains("bank-statement-3391.txt"), "\(supporting.hits.map(\.name))")
        #expect(!supporting.receipt.lines.isEmpty, "the run states what it searched")
        let contraryText = try #require(plan.contrary)
        let contrary = try #require(await search.run(caseID: c, text: contraryText, options: options).run)
        #expect(contrary.hits.map(\.name).contains("witness-meera.txt"), "the witness names Kestrel Supplies but not the figure: \(contrary.hits.map(\.name))")

        // 5. The check's receipt, recorded against the question and bound to it.
        let p1 = try #require(await caseMapLoad(f).projection)
        let check = try await f.file.recordClaimCheck(caseID: c, item: qNode, plan: plan, ran: plan.supporting, projection: p1, actor: "Ada")
        #expect(try await f.file.claimChecks(caseID: c).map(\.id) == [check])

        // 6. A child action for the distinguishing check, 7. its result recorded and reviewed at its exact revision.
        let action = try await f.svc.createAction(caseID: c, .init(title: "Match the refund to KS-77985", purpose: "Tell the two explanations apart",
                                                                   deliverable: "The refund's reference", servesQuestions: [question]), actor: "Ada")
        _ = try await f.file.recordActionResult(caseID: c, taskID: action, kind: .record, outcome: .successful,
                                                summary: "The 19 March refund carries no reference; it cannot be matched to KS-77985 on this statement",
                                                inputs: [.source(stmt.version, "bank statement 3391")], actor: "Ada")
        try await f.file.submitAction(caseID: c, taskID: action, note: nil, actor: "Ada")
        #expect(try await CaseMapWorkCommands.reviewResult(f.svc, caseID: c, taskID: action, accept: true,
                                                           rationale: "Read the statement line myself", actor: "Ada") == .selfReview)
        #expect(try await f.file.actionResultReviews(caseID: c).contains { $0.taskID == action && $0.revision == 1 })

        // 8. A revised brief: the first one stays readable; the computed brief says the case is inconclusive and why.
        let caseNode = CaseMapNodeID(caseID: c, kind: .caseFile, id: c)
        let v1 = try await f.file.writeBrief(caseID: c, anchor: caseNode, text: CaseBriefText(position: "Two debits of INR 50,000 are recorded."),
                                             expectedVersion: 0, actor: "Ada")
        let v2 = try await f.file.writeBrief(caseID: c, anchor: caseNode,
                                             text: CaseBriefText(position: "Two debits and one refund; the refund cannot yet be matched to the second debit.",
                                                                 alternatives: "A duplicate reversed by the refund"), expectedVersion: 1, actor: "Ada")
        let versions = try await f.file.briefLedger(caseID: c).versions(of: caseNode)
        #expect(versions.map(\.id) == [v2, v1] && versions.last?.position == "Two debits of INR 50,000 are recorded.", "the first brief is kept as written")
        let p2 = try #require(await caseMapLoad(f).projection)
        let brief = CaseMapBrief.compute(p2)
        #expect(brief.outcome.hasPrefix("Inconclusive on the available evidence."), "\(brief.outcome)")
        #expect(brief.section("completed")?.entries.contains { $0.node == CaseMapNodeID(caseID: c, kind: .task, id: action) } == true
                || brief.section("next")?.entries.contains { $0.node == CaseMapNodeID(caseID: c, kind: .task, id: action) } == true)
    }
}
