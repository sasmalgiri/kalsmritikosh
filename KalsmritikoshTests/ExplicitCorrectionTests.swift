//
//  ExplicitCorrectionTests.swift
//  KalsmritikoshTests
//
//  AEE-M2 — explicit corrections: a materially different answer after a visible revision is a
//  NEW `corrected` revision that names the prior revision it replaces and why; the prior
//  revision is never mutated; a correction cannot cross answers, cannot omit its reason, and
//  cannot re-state identical content. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M2 — explicit corrections", .serialized)
struct ExplicitCorrectionTests {

    private struct Rig { let repo: AnswerLedgerRepository; let db: Database; let dir: URL }
    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aee-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Rig(repo: AnswerLedgerRepository(database: db), db: db, dir: dir)
    }
    private func cite(_ obj: UUID = UUID()) -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: obj, chunkID: nil, eventID: nil, snippet: "")
    }
    private func working(_ rig: Rig, _ a: UUID, _ body: String) async throws -> UUID {
        try await rig.repo.appendWorkingResult(answerID: a, body: body, citations: [cite()], answerState: .supported, confidence: 0.8)
    }
    private func correct(_ rig: Rig, _ a: UUID, _ body: String, prior: UUID,
                         kind: CorrectionReasonKind = .contradictionDiscovered, detail: String? = nil) async throws -> UUID {
        try await rig.repo.recordCorrection(answerID: a, body: body, citations: [cite()], answerState: .supported,
            confidence: 0.8, correction: .init(priorRevisionID: prior, reasonKind: kind, detail: detail))
    }

    @Test("A correction referencing a non-existent prior revision is rejected")
    func correctionUnknownPrior() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        _ = try await working(rig, a, "First.")
        await #expect(throws: ProgressiveAnswerError.correctionCrossAnswer) {
            _ = try await correct(rig, a, "Second.", prior: UUID())
        }
    }

    @Test("A correction cannot reference a revision of a different answer")
    func correctionCrossAnswer() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "qa", mission: nil)
        let b = try await rig.repo.beginAnswer(question: "qb", mission: nil)
        _ = try await working(rig, a, "A body.")
        let bRev = try await working(rig, b, "B body.")
        await #expect(throws: ProgressiveAnswerError.correctionCrossAnswer) {
            _ = try await correct(rig, a, "A corrected.", prior: bRev)
        }
    }

    @Test("A correction of kind .other requires a nonblank detail")
    func correctionOtherRequiresDetail() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "First.")
        await #expect(throws: ProgressiveAnswerError.correctionReasonDetailRequired) {
            _ = try await correct(rig, a, "Second.", prior: r1, kind: .other, detail: "   ")
        }
    }

    @Test("A correction that does not change content is rejected")
    func correctionUnchangedContent() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let obj = UUID()
        let r1 = try await rig.repo.appendWorkingResult(answerID: a, body: "Same.", citations: [cite(obj)], answerState: .supported, confidence: 0.8)
        await #expect(throws: ProgressiveAnswerError.contentUnchanged) {
            _ = try await rig.repo.recordCorrection(answerID: a, body: "Same.", citations: [cite(obj)], answerState: .supported,
                confidence: 0.8, correction: .init(priorRevisionID: r1, reasonKind: .additionalEvidence))
        }
    }

    @Test("A valid correction creates a new revision and preserves the prior one verbatim")
    func validCorrectionPreservesPrior() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "Original.")
        let priorBody = try await rig.db.query("SELECT body, content_hash FROM answer_revisions WHERE id = ?;", [.uuid(r1)]).first
        let r2 = try await correct(rig, a, "Corrected.", prior: r1)
        #expect(r1 != r2)
        // The prior revision row is UNCHANGED.
        let after = try await rig.db.query("SELECT body, content_hash FROM answer_revisions WHERE id = ?;", [.uuid(r1)]).first
        #expect(after?.string(0) == priorBody?.string(0))
        #expect(after?.string(1) == priorBody?.string(1))
        #expect(try await rig.db.query("SELECT COUNT(*) FROM answer_revisions WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 2)
    }

    @Test("A correction records what it replaced and why")
    func correctionCarriesReasonAndKind() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "Original.")
        let r2 = try await correct(rig, a, "Corrected.", prior: r1, kind: .contradictionDiscovered, detail: "found a conflict")
        let row = try #require(try await rig.db.query("SELECT correction_of_revision_id, correction_reason, correction_reason_kind FROM answer_revisions WHERE id = ?;", [.uuid(r2)]).first)
        #expect(row.uuid(0) == r1)
        #expect((row.string(1) ?? "").isEmpty == false)
        #expect(row.string(2) == CorrectionReasonKind.contradictionDiscovered.rawValue)
    }

    @Test("The corrected event follows the working result in the lifecycle")
    func correctedEventEmitted() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "Original.")
        _ = try await correct(rig, a, "Corrected.", prior: r1)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.events.map(\.state) == [.groundedWorkingResult, .corrected])
    }

    @Test("A user correction is stored as user-attributed and does not force a verified state")
    func userCorrectionAttribution() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "Original.")
        let r2 = try await rig.repo.recordCorrection(answerID: a, body: "User says otherwise.", citations: [cite()],
            answerState: .partiallySupported, confidence: 0.4,
            correction: .init(priorRevisionID: r1, reasonKind: .userCorrection, detail: "user note"))
        let kindRaw = try await rig.db.query("SELECT correction_reason_kind FROM answer_revisions WHERE id = ?;", [.uuid(r2)]).first?.string(0)
        let kind = try #require(kindRaw.flatMap(CorrectionReasonKind.init(rawValue:)))
        #expect(kind.isUserAttributed)
        // It is NOT elevated to a verified/supported state on its own.
        #expect(try await rig.db.query("SELECT answer_state FROM answer_revisions WHERE id = ?;", [.uuid(r2)]).first?.string(0) == AnswerState.partiallySupported.rawValue)
    }

    @Test("A correction can occur after review-ready, then re-review and finalise on the corrected revision")
    func correctionAfterReviewReadyFinalises() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "First working.")
        try await rig.repo.markReviewReady(answerID: a)
        let r2 = try await correct(rig, a, "Corrected after review.", prior: r1, kind: .sourceUpgradeChangedEvidence)
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        // The final answers projection is the CORRECTED revision's body.
        #expect(try await rig.db.query("SELECT body FROM answers WHERE id = ?;", [.uuid(a)]).first?.string(0) == "Corrected after review.")
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.latestState == .verifiedFinal)
        #expect(hist.revisions.contains { $0.id == r2 && $0.isCorrection })
    }

    @Test("The full corrected path finalises with two revisions preserved")
    func fullCorrectedPath() async throws {
        let rig = try await makeRig()
        let a = try await rig.repo.beginAnswer(question: "q", mission: nil)
        let r1 = try await working(rig, a, "V1.")
        _ = try await correct(rig, a, "V2 corrected.", prior: r1, kind: .additionalEvidence)
        try await rig.repo.markReviewReady(answerID: a)
        try await rig.repo.lockVerifiedFinal(answerID: a)
        let hist = try await rig.repo.history(answerID: a)
        #expect(hist.revisions.count == 2)
        #expect(hist.isTerminal)
        #expect(hist.events.map(\.state) == [.groundedWorkingResult, .corrected, .reviewReady, .verifiedFinal])
    }
}
