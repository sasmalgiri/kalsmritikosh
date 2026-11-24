//
//  ALCOAGroup2Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 2 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-02 attributable AI (runs, record
//  provenance, the person's decisions), ALC-07 traceable (new chain sources, append-only core logs), ALC-08 reliable model
//  (served model logged, fallback labelled, fair-eval gate), ALC-10 complete (revision capture with a reason).
//  Scripted readers only: no model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 2 — ALC-02/07/08/10", .serialized)
struct ALCOAGroup2Tests {

    static let asked = "model-asked-for"
    static let served = "model-that-answered"

    // MARK: - ALC-02

    @Test("ALC-02: every question and picture pass is a run (provider, model asked/served, person, inputs, coverage, usage); its records link to it")
    func attributedRunsAndRecords() async throws {
        let r = try await AgentSplitX2Tests.rig(AgentSplitX2Tests.docs(), served: { _ in Self.served }, requested: Self.asked) { send in
            send.purpose == "case.picture" ? AgentSplitX2Tests.pictureReply(send) : AgentSplitX2Tests.questionReply(send)
        }
        _ = try await r.service.answer(caseID: r.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted())
        let runs = try await r.repo.runs(caseID: r.caseID)
        let picture = try #require(runs.first { $0.kind == "picture" }), question = try #require(runs.first { $0.kind == "question" })
        for run in [picture, question] {
            #expect(run.state == "done" && run.provider == "anthropic" && run.modelRequested == Self.asked, "\(run)")
            #expect(run.modelServed == Self.served && run.fallback, "another model answered: labelled a fallback")
            #expect(run.requestedBy == "this Mac's owner")
        }
        let row = try #require(try await r.db.query("""
            SELECT input_revisions_json, coverage_json, model_calls, input_tokens, prompt_version, length(cache_key) FROM case_ai_runs WHERE id = ?;
            """, [.uuid(question.id)]).first)
        #expect((row.string(0) ?? "").contains("-") && (row.string(1) ?? "").contains("\"sent\":2"), "inputs and coverage recorded")
        #expect((row.int(2) ?? 0) >= 2 && (row.int(3) ?? 0) >= 200, "every call counted")
        #expect(row.string(4) == CaseAgent.promptVersion && row.int(5) == 64)
        let records = try await r.repo.records(caseID: r.caseID)
        #expect(!records.isEmpty)
        for rec in records {
            #expect(rec.runID == picture.id, "a picture record links to its run")
            #expect(rec.modelRequested == Self.asked && rec.modelServed == Self.served && rec.requestedBy == "this Mac's owner")
            #expect(rec.promptVersion == CaseAgent.promptVersion && rec.requestSHA256?.count == 64)
        }
        #expect(CaseAIReviewText.provenance(records[0], run: picture).contains("answered by \(Self.served) (fallback)"))
    }

    @Test("ALC-02: a finished run is never edited; the run kinds the agent uses are admitted")
    func runIsFixed() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let start = CaseAIRecordRepository.RunStart(kind: .question, task: "q", provider: "anthropic", modelRequested: Self.asked, requestedBy: "Asha",
                                                    documentsFingerprint: "fp", inputVersions: [UUID()], coverage: ["sent": 1], promptVersion: CaseAgent.promptVersion)
        let id = try await repo.openRun(caseID: f.caseA, start)
        var u = CloudCallUsage(inputTokens: 5, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 1, purpose: "case.question", provider: "anthropic")
        u.model = Self.asked
        try await repo.finishRun(id, caseID: f.caseA, state: "done", reason: nil, usage: [u], counts: ["recordsStored": 0])
        let run = try #require(try await repo.runs(caseID: f.caseA).first)
        #expect(run.requestedBy == "Asha" && run.modelServed == Self.asked && !run.fallback)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_ai_runs SET answered_by_model = 'x' WHERE id = ?;", [.uuid(id)])
        }
        await f.state.shutdown()
    }

    @Test("ALC-02: accept / reject / correct with approver and reason, append-only; a final report uses only accepted or corrected findings")
    func decisionsAndFinalReport() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        let a = CaseAIRecord(kind: .fact, text: "Kestrel was paid twice", quote: "debit INR 50,000 to Kestrel", document: doc, origin: "picture")
        let b = CaseAIRecord(kind: .fact, text: "Meera approved the amendment", quote: "Approved by Meera Iyer", document: doc, origin: "picture")
        let c = CaseAIRecord(kind: .fact, text: "The refund came on 18 March", quote: "19 Mar 2026: credit", document: doc, origin: "picture")
        try await repo.record(caseID: f.caseA, [a, b, c])
        // Rules: a reject or correct needs a reason; a correct needs wording; an approver is named.
        await #expect(throws: CaseAIRecordRepository.DecisionError.reasonNeeded) { try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: " ", approver: "Asha") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.correctionNeeded) { try await repo.decide(caseID: f.caseA, recordID: c.id, .correct, reason: "date", approver: "Asha") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.blankApprover) { try await repo.decide(caseID: f.caseA, recordID: b.id, .accept, reason: nil, approver: "") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.notInCase) { try await repo.decide(caseID: f.caseB, recordID: b.id, .accept, reason: nil, approver: "Asha") }
        try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: "paid once; the second debit is INV-109", approver: "Asha")
        try await repo.decide(caseID: f.caseA, recordID: b.id, .accept, reason: nil, approver: "Asha")
        try await repo.decide(caseID: f.caseA, recordID: c.id, .correct, correctedText: "The refund came on 19 March", reason: "the date is 19 Mar", approver: "Asha")
        // A later decision is a new row; the latest counts.
        try await repo.decide(caseID: f.caseA, recordID: a.id, .accept, reason: nil, approver: "Ravi")
        #expect(try await repo.decisions(caseID: f.caseA).count == 4)
        #expect(try await repo.latestDecisions(caseID: f.caseA)[a.id]?.approver == "Ravi")
        let final = try await repo.reportRecords(caseID: f.caseA, final: true).map(\.text)
        #expect(Set(final) == ["Kestrel was paid twice", "Meera approved the amendment", "The refund came on 19 March"])
        try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: "on reflection, paid once", approver: "Ravi")
        let final2 = try await repo.reportRecords(caseID: f.caseA, final: true).map(\.text)
        #expect(!final2.contains("Kestrel was paid twice"))
        #expect(try await repo.reportRecords(caseID: f.caseA, final: false).count == 3, "a draft lists every finding")
        let text = CaseAIRecordRepository.reportText(try await repo.reportRecords(caseID: f.caseA, final: true), final: true)
        #expect(text.hasPrefix("AI findings — final") && text.contains("approved"))
        // Append-only.
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_ai_record_decisions SET approver = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_ai_record_decisions;", []) }
        #expect(CaseAIReviewText.decision(try await repo.latestDecisions(caseID: f.caseA)[c.id]).contains("Corrected by Asha"))
        // A case erasure takes them with the case.
        let report = try await CaseEraser(database: f.db).erase(caseID: f.caseA, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                reason: "test", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_record_decisions;", []) == 0)
        await f.state.shutdown()
    }
}
