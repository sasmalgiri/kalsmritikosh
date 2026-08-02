//
//  AEEM2MasterBrainIntegrationTests.swift
//  KalsmritikoshTests
//
//  AEE-M2 — the durable-commit-before-display contract at the MasterBrain seam
//  (finalizeProgressiveAnswer): a groundable answer commits working-result → review-ready →
//  verifiedFinal in the ledger BEFORE verifiedFinal is emitted; a refused/uncited answer or a
//  persistence failure yields incomplete, never a final; mission metadata is projected; and
//  with no ledger wired the terminal state is still emitted. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M2 — MasterBrain durable answer integration", .serialized)
struct AEEM2MasterBrainIntegrationTests {

    private func makeLedger(atVersion v: Int = 89) async throws -> (AnswerLedgerRepository, Database) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aee-m2-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        if v >= SchemaMigrations.latestVersion { try await SchemaMigrations.migrate(db) }
        else { try await SchemaMigrations.migrate(db, through: v) }
        try await db.exec("PRAGMA foreign_keys = ON;")
        return (AnswerLedgerRepository(database: db), db)
    }

    private func groundable(_ body: String = "Paid 500.") -> VerifiedAnswer {
        VerifiedAnswer(body: body,
                       citations: [VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: nil, snippet: "s")],
                       confidence: .medium, refused: false, refusalReason: nil)
    }
    private func refused() -> VerifiedAnswer {
        VerifiedAnswer(body: "no answer", citations: [], confidence: .zero, refused: true, refusalReason: "insufficient evidence")
    }
    private func uncited() -> VerifiedAnswer {
        VerifiedAnswer(body: "some prose", citations: [], confidence: .low, refused: false, refusalReason: nil)
    }
    private func mission() -> QueryMission {
        let i = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much?")
        let p = QueryPlanCompiler().compile(intent: i, category: .fact, queryClass: .ordinary)
        return QueryMissionCompiler().compile(intent: i, category: .fact, queryClass: .ordinary, plan: p, context: AEERequestContext())
    }
    private func label(_ u: AnswerUpdate) -> String {
        switch u {
        case .immediateFinding: return "immediateFinding"
        case .groundedWorkingResult: return "groundedWorkingResult"
        case .analysisProgress: return "analysisProgress"
        case .reviewReady: return "reviewReady"
        case .verifiedFinal: return "verifiedFinal"
        case .corrected: return "corrected"
        case .incomplete: return "incomplete"
        default: return "legacy"
        }
    }

    @Test("A groundable answer emits working-result → review-ready → verifiedFinal")
    func groundableEmitsLifecycle() async throws {
        let (ledger, _) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: groundable(), mission: mission())
        #expect(updates.map(label) == ["groundedWorkingResult", "reviewReady", "verifiedFinal"])
    }

    @Test("verifiedFinal is emitted only after the durable ledger commit exists")
    func verifiedFinalIsDurable() async throws {
        let (ledger, db) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)
        _ = await brain.finalizeProgressiveAnswer(question: "q", verified: groundable(), mission: mission())
        // A terminal, committed answer exists with a verifiedFinal event.
        let terminal = try await db.query("SELECT COUNT(*) FROM answers WHERE is_terminal = 1;", []).first?.int(0)
        #expect(terminal == 1)
        let finalEvents = try await db.query("SELECT COUNT(*) FROM answer_revision_events WHERE state = 'verifiedFinal';", []).first?.int(0)
        #expect(finalEvents == 1)
    }

    @Test("A persistence failure yields incomplete, never verifiedFinal")
    func persistenceFailureYieldsIncomplete() async throws {
        // A v88 ledger lacks answer_revisions/compat columns → beginAnswer/appendWorkingResult throw.
        let (ledger, _) = try await makeLedger(atVersion: 88)
        let brain = MasterBrain(answerLedger: ledger)
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: groundable(), mission: mission())
        #expect(updates.map(label) == ["incomplete"])
    }

    @Test("A refused answer is recorded incomplete")
    func refusedIncomplete() async throws {
        let (ledger, db) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: refused(), mission: mission())
        #expect(updates.map(label) == ["incomplete"])
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revision_events WHERE state = 'incomplete';", []).first?.int(0) == 1)
    }

    @Test("An uncited answer is incomplete, not a confident final")
    func uncitedIncomplete() async throws {
        let (ledger, _) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: uncited(), mission: mission())
        #expect(updates.map(label) == ["incomplete"])
    }

    @Test("With no ledger wired, a groundable answer still emits verifiedFinal (degraded)")
    func noLedgerDegradedFinal() async throws {
        let brain = MasterBrain()   // no answer ledger
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: groundable(), mission: nil)
        #expect(updates.map(label) == ["verifiedFinal"])
    }

    @Test("With no ledger wired, a refused answer emits incomplete")
    func noLedgerRefusedIncomplete() async throws {
        let brain = MasterBrain()
        let updates = await brain.finalizeProgressiveAnswer(question: "q", verified: refused(), mission: nil)
        #expect(updates.map(label) == ["incomplete"])
    }

    @Test("The mission's lane is projected onto the durable answer row")
    func missionMetadataProjected() async throws {
        let (ledger, db) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)
        let m = mission()
        _ = await brain.finalizeProgressiveAnswer(question: "q", verified: groundable(), mission: m)
        #expect(try await db.query("SELECT mission_lane FROM answers LIMIT 1;", []).first?.string(0) == m.primaryLane.rawValue)
    }

    @Test("The answer() wrapper returns the terminal answer via the incomplete path when the pipeline is unbooted")
    func answerWrapperTerminal() async throws {
        let (ledger, _) = try await makeLedger()
        let brain = MasterBrain(answerLedger: ledger)   // no pipeline deps → refused boot answer → incomplete
        let answer = await brain.answer(question: "anything", access: .testUnrestricted())
        #expect(answer.refused)   // the terminal VerifiedAnswer is surfaced
    }
}
