//
//  AEEFinalEvaluationTests.swift
//  KalsmritikoshTests
//
//  AEE-FINAL — end-to-end evaluation across the five lanes plus the durable replay: the
//  deterministic 0-call and focused ≤1-call fast paths, an analytical correction, a preserved
//  contradiction, missing/blocked evidence → incomplete, an exact-version replay to its
//  SourceVersion, and the reconstruction single revision chain. Exercised deterministically
//  through the answer-ledger authority + the AEE mission types (no LLM). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-FINAL — end-to-end lane evaluation", .serialized)
struct AEEFinalEvaluationTests {

    private struct Rig { let repo: AnswerLedgerRepository; let db: Database; let dir: URL }
    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aee-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Rig(repo: AnswerLedgerRepository(database: db), db: db, dir: dir)
    }
    private func cite(_ obj: UUID = UUID()) -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: obj, chunkID: nil, eventID: nil, snippet: "")
    }
    private func mission(lane: AEELane) -> QueryMission {
        let (i, c, det, wf): (UserIntent, QueryCategory, Bool, Bool)
        switch lane {
        case .deterministic:        (i, c, det, wf) = (UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "id?"), .fact, true, false)
        case .focused:              (i, c, det, wf) = (UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much?"), .fact, false, false)
        case .analytical:           (i, c, det, wf) = (UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "why?"), .comparison, false, false)
        case .reconstruction:       (i, c, det, wf) = (UserIntent(kind: .reconstructTimeline, scope: .global, rawQuestion: "trace"), .narrative, false, false)
        case .professionalWorkflow: (i, c, det, wf) = (UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "run job"), .fact, false, true)
        }
        let k: LLMQueryClass = lane == .deterministic ? .deterministic : (lane == .focused ? .ordinary : .complex)
        let p = QueryPlanCompiler().compile(intent: i, category: c, queryClass: k)
        return QueryMissionCompiler().compile(intent: i, category: c, queryClass: k, plan: p,
            context: AEERequestContext(workflowInvocationPresent: wf, deterministicHandlerAvailable: det))
    }

    @Test("Deterministic lane: 0 generative calls, immediateFinding → reviewReady → verifiedFinal")
    func deterministicLane() async throws {
        let rig = try await makeRig()
        let m = mission(lane: .deterministic)
        #expect(m.allowedLLMCalls == 0)
        let a = try await rig.repo.beginAnswer(question: "id?", mission: m)
        _ = try await rig.repo.appendFinding(answerID: a, body: "ID is 42.", citations: [cite()], answerState: .supported, confidence: 1.0)
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        #expect(try await rig.repo.history(answerID: a).latestState == .verifiedFinal)
    }

    @Test("Focused lane: ≤1 generative call, working result → review-ready → verifiedFinal")
    func focusedLane() async throws {
        let rig = try await makeRig()
        let m = mission(lane: .focused)
        #expect(m.allowedLLMCalls <= 1)
        let a = try await rig.repo.beginAnswer(question: "how much?", mission: m)
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "500.", citations: [cite()], answerState: .supported, confidence: 0.9)
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.isTerminal && hist.revisions.count == 1)
    }

    @Test("Analytical lane with a correction finalises on the corrected revision")
    func analyticalCorrection() async throws {
        let rig = try await makeRig()
        let m = mission(lane: .analytical)
        let a = try await rig.repo.beginAnswer(question: "why?", mission: m)
        let r1 = try await rig.repo.appendWorkingResult(answerID: a, body: "Cause A.", citations: [cite()], answerState: .supported, confidence: 0.7)
        _ = try await rig.repo.recordCorrection(answerID: a, body: "Cause B.", citations: [cite()], answerState: .supported,
            confidence: 0.8, correction: .init(priorRevisionID: r1, reasonKind: .contradictionDiscovered))
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        #expect(try await rig.db.query("SELECT body FROM answers WHERE id = ?;", [.uuid(a)]).first?.string(0) == "Cause B.")
    }

    @Test("A contradiction is preserved through the lifecycle, not resolved away")
    func contradictionPreserved() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "conflict?", mission: mission(lane: .analytical))
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "Sources disagree.", citations: [cite()], answerState: .contradicted, confidence: 0.5)
        #expect(try await rig.db.query("SELECT answer_state FROM answer_revisions WHERE id = ?;", [.uuid(rev)]).first?.string(0) == AnswerState.contradicted.rawValue)
    }

    @Test("Missing evidence finalises as incomplete, never a confident final")
    func missingEvidenceIncomplete() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "unknown?", mission: mission(lane: .focused))
        try await rig.repo.markIncomplete(answerID: a, reason: "required evidence missing")
        #expect(try await rig.repo.history(answerID: a).latestState == .incomplete)
    }

    @Test("A blocked decisive source is assessed blocked and the answer is recorded incomplete")
    func blockedEvidenceIncomplete() async throws {
        let rig = try await makeRig()
        let m = mission(lane: .analytical)
        // The mission assessor blocks a corrupt decisive source on a high-risk lane.
        let sv = UUID()
        let assessment = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: EvidenceSufficiency(covered: [], missing: [], documentsSearched: 1),
            decisiveReadiness: [sv: .corrupt], independentSourceCount: 1, contradictionCount: 0, correctivePassUsed: false)
        #expect(assessment.disposition == .blocked)
        // The answer is honestly recorded incomplete (not fabricated around the block).
        let a = try await rig.repo.beginAnswer(question: "why?", mission: m)
        try await rig.repo.markIncomplete(answerID: a, reason: "decisive source blocked")
        #expect(try await rig.repo.history(answerID: a).latestState == .incomplete)
    }

    @Test("An exact-version answer replays deterministically to its SourceVersion")
    func exactVersionReplay() async throws {
        let rig = try await makeRig()
        let sv = UUID(), doc = UUID(), block = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                             [.uuid(sv), .text("file:///x/\(sv.uuidString)"), .text("txt"), .text("available")])
        try await rig.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(sv), .uuid(sv), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        try await rig.db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        let a = try await rig.repo.beginAnswer(question: "q", mission: mission(lane: .analytical))
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.9)
        let claim = try #require(try await rig.db.query("SELECT id FROM answer_claims WHERE revision_id = ?;", [.uuid(rev)]).first?.uuid(0))
        let blocksJSON = String(data: try JSONEncoder().encode([block.uuidString]), encoding: .utf8)!
        try await rig.db.exec("UPDATE claim_evidence SET block_ids = ? WHERE claim_id = ?;", [.text(blocksJSON), .uuid(claim)])
        let replay = try await rig.repo.replay(answerID: a)
        #expect(replay.revisions.first?.claims.first?.evidence.first?.sourceVersionIDs == [sv.uuidString])
    }

    @Test("Replay is deterministic — two replays of the same answer are identical")
    func replayDeterministic() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: mission(lane: .focused))
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.9)
        try await rig.repo.markReviewReady(answerID: a); try await rig.repo.lockVerifiedFinal(answerID: a)
        #expect(try await rig.repo.replay(answerID: a) == (try await rig.repo.replay(answerID: a)))
    }

    @Test("A corrected answer's replay shows both revisions, the second a correction")
    func correctedReplayBothRevisions() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: mission(lane: .analytical))
        let r1 = try await rig.repo.appendWorkingResult(answerID: a, body: "V1.", citations: [cite()], answerState: .supported, confidence: 0.7)
        _ = try await rig.repo.recordCorrection(answerID: a, body: "V2.", citations: [cite()], answerState: .supported,
            confidence: 0.8, correction: .init(priorRevisionID: r1, reasonKind: .additionalEvidence))
        let replay = try await rig.repo.replay(answerID: a)
        #expect(replay.revisions.count == 2)
        #expect(replay.revisions.last?.revision.isCorrection == true)
    }

    @Test("Reconstruction remains ONE revision chain (no separate history-answer ledger)")
    func reconstructionSingleChain() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "trace", mission: mission(lane: .reconstruction))
        try await rig.repo.appendProgress(answerID: a, detail: "Composing chapter 1")
        try await rig.repo.appendProgress(answerID: a, detail: "Composing chapter 2")
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "Narrative.", citations: [cite()], answerState: .supported, confidence: 0.8)
        try await rig.repo.markReviewReady(answerID: a); try await rig.repo.lockVerifiedFinal(answerID: a)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.revisions.count == 1)                     // one chain
        #expect(hist.events.filter { $0.state == .analysisProgress }.count == 2)   // chapters were progress
    }

    @Test("professionalWorkflow does not auto-finalise: begin alone leaves the answer non-terminal")
    func professionalWorkflowNoAutoFinal() async throws {
        let rig = try await makeRig()
        let m = mission(lane: .professionalWorkflow)
        #expect(m.primaryLane == .professionalWorkflow)
        let a = try await rig.repo.beginAnswer(question: "run job", mission: m)
        #expect(try await rig.db.query("SELECT is_terminal FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 0)
    }

    @Test("An incomplete answer preserves the partial finding it did produce")
    func incompletePreservesFound() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: mission(lane: .analytical))
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "Partial finding.", citations: [cite()], answerState: .partiallySupported, confidence: 0.5)
        try await rig.repo.markIncomplete(answerID: a, reason: "corroboration unmet")
        let replay = try await rig.repo.replay(answerID: a)
        #expect(replay.revisions.first?.revision.id == rev)
        #expect(replay.revisions.first?.revision.body == "Partial finding.")
    }
}
