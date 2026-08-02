//
//  AnswerRevisionLedgerTests.swift
//  KalsmritikoshTests
//
//  AEE-M2 — the revision writer on the ONE answer-ledger authority: begin → finding/working
//  result → progress → review-ready → verifiedFinal / incomplete, each in a single savepoint.
//  Proves claims are pinned to their exact revision, terminal locking projects into the
//  answers row, further writes after terminal are rejected, and deterministic replay reaches
//  the exact EvidenceBlocks / SourceVersions. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M2 — answer revision ledger", .serialized)
struct AnswerRevisionLedgerTests {

    private struct Rig { let repo: AnswerLedgerRepository; let db: Database; let dir: URL }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aee-m2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Rig(repo: AnswerLedgerRepository(database: db), db: db, dir: dir)
    }

    private func cite(_ obj: UUID = UUID(), event: UUID? = nil, snippet: String = "") -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: obj, chunkID: nil, eventID: event, snippet: snippet)
    }

    @Test("beginAnswer creates a non-terminal header with mission metadata")
    func beginAnswerHeader() async throws {
        let rig = try await makeRig()
        let i = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much?")
        let plan = QueryPlanCompiler().compile(intent: i, category: .fact, queryClass: .ordinary)
        let mission = QueryMissionCompiler().compile(intent: i, category: .fact, queryClass: .ordinary, plan: plan, context: AEERequestContext())
        let id = try await rig.repo.beginAnswer(question: "how much?", mission: mission)
        let row = try #require(try await rig.db.query("SELECT is_terminal, mission_lane, request_id FROM answers WHERE id = ?;", [.uuid(id)]).first)
        #expect(row.int(0) == 0)
        #expect(row.string(1) == mission.primaryLane.rawValue)
        #expect(row.uuid(2) == mission.requestID)
    }

    @Test("A working result creates revision 1 with a claim pinned to that exact revision")
    func workingResultRevisionAndClaim() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "Paid 500.", citations: [cite()], answerState: .supported, confidence: 0.8)
        #expect(try await rig.db.query("SELECT revision_number FROM answer_revisions WHERE id = ?;", [.uuid(rev)]).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM answer_claims WHERE revision_id = ?;", [.uuid(rev)]).first?.int(0) == 1)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.latestState == .groundedWorkingResult)
    }

    @Test("A finding may be refined into a working result (two revisions)")
    func findingThenWorkingResult() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await rig.repo.appendFinding(answerID: a, body: "Provisional.", citations: [cite()], answerState: .partiallySupported, confidence: 0.4)
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "Grounded richer answer.", citations: [cite()], answerState: .supported, confidence: 0.8)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM answer_revisions WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 2)
    }

    @Test("Identical content does not create an unnecessary second revision")
    func idempotentSameContent() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let obj = UUID()
        let r1 = try await rig.repo.appendFinding(answerID: a, body: "Same body.", citations: [cite(obj)], answerState: .supported, confidence: 0.6)
        let r2 = try await rig.repo.appendWorkingResult(answerID: a, body: "Same body.", citations: [cite(obj)], answerState: .supported, confidence: 0.6)
        #expect(r1 == r2)   // idempotent no-op
        #expect(try await rig.db.query("SELECT COUNT(*) FROM answer_revisions WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 1)
    }

    @Test("markReviewReady requires a content revision")
    func reviewReadyRequiresContent() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        await #expect(throws: ProgressiveAnswerError.noContentRevisionToReview) { try await rig.repo.markReviewReady(answerID: a) }
    }

    @Test("lockVerifiedFinal requires review-ready first")
    func finalRequiresReviewReady() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "Body.", citations: [cite()], answerState: .supported, confidence: 0.8)
        await #expect(throws: ProgressiveAnswerError.notReviewReady) { try await rig.repo.lockVerifiedFinal(answerID: a) }
    }

    @Test("The happy path finalises: terminal, projected body, verifiedFinal event")
    func happyPath() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "Final body.", citations: [cite()], answerState: .supported, confidence: 0.9)
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        let row = try #require(try await rig.db.query("SELECT is_terminal, body FROM answers WHERE id = ?;", [.uuid(a)]).first)
        #expect(row.int(0) == 1)
        #expect(row.string(1) == "Final body.")
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.latestState == .verifiedFinal)
        #expect(hist.isTerminal)
    }

    @Test("A terminal answer rejects further writes")
    func terminalRejectsWrites() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        try await rig.repo.markIncomplete(answerID: a, reason: "no evidence")
        await #expect(throws: ProgressiveAnswerError.answerAlreadyTerminal) {
            try await rig.repo.appendWorkingResult(answerID: a, body: "x", citations: [cite()], answerState: .supported, confidence: 0.5)
        }
    }

    @Test("appendProgress records a revision-less analysisProgress event (repeatable)")
    func progressNoRevision() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        try await rig.repo.appendProgress(answerID: a, detail: "searching")
        try await rig.repo.appendProgress(answerID: a, detail: "verifying")
        let rows = try await rig.db.query("SELECT revision_id, state FROM answer_revision_events WHERE answer_id = ? ORDER BY sequence;", [.uuid(a)])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.isNull(0) && $0.string(1) == "analysisProgress" })
    }

    @Test("markIncomplete may be revision-less and marks the answer terminal")
    func incompleteRevisionless() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        try await rig.repo.markIncomplete(answerID: a, reason: "budget exhausted")
        let ev = try #require(try await rig.db.query("SELECT revision_id, state FROM answer_revision_events WHERE answer_id = ?;", [.uuid(a)]).first)
        #expect(ev.isNull(0) == true)
        #expect(ev.string(1) == "incomplete")
        #expect(try await rig.db.query("SELECT is_terminal FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 1)
    }

    @Test("markIncomplete after a working result references that partial revision")
    func incompleteWithPartial() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "Partial.", citations: [cite()], answerState: .partiallySupported, confidence: 0.5)
        try await rig.repo.markIncomplete(answerID: a, reason: "blocked source")
        let ev = try #require(try await rig.db.query("SELECT revision_id FROM answer_revision_events WHERE answer_id = ? AND state='incomplete';", [.uuid(a)]).first)
        #expect(ev.uuid(0) == rev)
    }

    @Test("history returns ordered revisions + events with the latest state")
    func historyOrdered() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await rig.repo.appendWorkingResult(answerID: a, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.9)
        try await rig.repo.appendProgress(answerID: a, detail: "checking")
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.revisions.count == 1)
        #expect(hist.events.map(\.state) == [.groundedWorkingResult, .analysisProgress, .reviewReady, .verifiedFinal])
        #expect(hist.latestState == .verifiedFinal)
    }

    @Test("A new claim is pinned to the exact revision it belongs to")
    func claimPinnedToRevision() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.9)
        #expect(try await rig.db.query("SELECT revision_id FROM answer_claims WHERE answer_id = ?;", [.uuid(a)]).first?.uuid(0) == rev)
    }

    @Test("Deterministic replay reaches the exact block and its source version")
    func replayReachesBlockAndVersion() async throws {
        let rig = try await makeRig()
        // Seed a source version + an evidence block belonging to it.
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

        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let rev = try await rig.repo.appendWorkingResult(answerID: a, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.9)
        // Attach the block to the revision's claim evidence (bypassing the FTS resolver).
        let claim = try #require(try await rig.db.query("SELECT id FROM answer_claims WHERE revision_id = ?;", [.uuid(rev)]).first?.uuid(0))
        let blocksJSON = String(data: try JSONEncoder().encode([block.uuidString]), encoding: .utf8)!
        try await rig.db.exec("UPDATE claim_evidence SET block_ids = ? WHERE claim_id = ?;", [.text(blocksJSON), .uuid(claim)])

        let replay = try await rig.repo.replay(answerID: a)
        let leaf = try #require(replay.revisions.first?.claims.first?.evidence.first)
        #expect(leaf.blockIDs == [block.uuidString])
        #expect(leaf.sourceVersionIDs == [sv.uuidString])
    }

    @Test("recoverInterruptedAnswers marks non-terminal v89 answers incomplete, leaving legacy answers alone")
    func recoverInterrupted() async throws {
        let rig = try await makeRig()
        // A legacy (pre-lifecycle) answer: header only, no events.
        let legacy = UUID()
        try await rig.db.exec("INSERT INTO answers (id, question, answer_state, body, confidence, created_at) VALUES (?,?,?,?,?,?);",
                             [.uuid(legacy), .text("legacy"), .text("supported"), .text("body"), .real(0.5), .real(1)])
        // An interrupted v89 answer: has a working result but no terminal event.
        let live = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await rig.repo.appendWorkingResult(answerID: live, body: "B.", citations: [cite()], answerState: .supported, confidence: 0.8)
        let recovered = try await rig.repo.recoverInterruptedAnswers()
        #expect(recovered == [live])
        #expect(try await rig.repo.history(answerID: live).latestState == .incomplete)
        // The legacy answer is untouched (still non-terminal, no events).
        #expect(try await rig.db.query("SELECT COUNT(*) FROM answer_revision_events WHERE answer_id = ?;", [.uuid(legacy)]).first?.int(0) == 0)
    }
}
