//
//  MethodLifecycleEpochEnforcementTests.swift
//  KalsmritikoshTests
//
//  PM-004.1 — the authoritative repository primitive applyLifecyclePlan enforces the
//  gate epochs itself, not trusting caller-supplied values: a review must evaluate the
//  run's effective content revision (current, or current+1 for a content-changing
//  reopen), and a validation batch must be one non-legacy batch, every row owned by the
//  run and evaluating the current content revision. The lifecycle engine already
//  constructs these correctly; these tests drive the public primitive with hand-built
//  plans to prove it is self-enforcing.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004.1 — lifecycle plan epoch enforcement", .serialized)
struct MethodLifecycleEpochEnforcementTests {

    private let t0 = PM004Fixtures.t0

    /// A run left active with content; returns (runID, revision, contentRevision).
    private func seeded(_ rig: PM004Rig) async throws -> (UUID, Int, Int) {
        let runID = try await PM004Fixtures.seedRun(rig)
        let run = try #require(try await rig.repo.run(id: runID))
        return (runID, run.revision, run.contentRevision)
    }

    private func reviewPlan(reviewKey: String = "final", contentChanged: Bool,
                            reviewedContentRevision: Int) -> MethodLifecyclePlan {
        let review = MethodReview(
            methodRunID: UUID(), reviewKey: reviewKey, reviewedContentRevision: reviewedContentRevision,
            action: .acceptForWorkflow, actorIdentifier: "reviewer", reviewedAt: t0)
        return MethodLifecyclePlan(
            action: .reviewRecorded,
            patch: .init(toStatus: .active, contentChanged: contentChanged),
            review: review, actorKind: .human, actorIdentifier: "reviewer")
    }

    private func validationPlan(_ rows: [MethodValidationResult]) -> MethodLifecyclePlan {
        MethodLifecyclePlan(
            action: .validationRecorded, patch: .init(toStatus: .active),
            validationBatch: rows, actorKind: .human, actorIdentifier: "analyst")
    }

    private func validationRow(runID: UUID, batchID: UUID, rev: Int) -> MethodValidationResult {
        MethodValidationResult(
            methodRunID: runID, validatorID: "v.structure", validatorVersion: "1",
            severity: .info, code: "OK", message: "fine", subjectKind: .run,
            validationBatchID: batchID, evaluatedContentRevision: rev, createdAt: t0)
    }

    // MARK: - Review epoch

    @Test("A review evaluating a revision other than the current one is rejected")
    func reviewEpochMismatchRejected() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        await #expect(throws: MethodPersistenceError.reviewEpochMismatch(runID: runID, expected: cr, actual: cr + 5)) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev,
                plan: self.reviewPlan(contentChanged: false, reviewedContentRevision: cr + 5), now: self.t0)
        }
        #expect(try await rig.repo.run(id: runID)?.revision == rev)   // nothing written
        #expect(try await rig.repo.reviews(runID: runID).isEmpty)
    }

    @Test("A review evaluating the current content revision is accepted")
    func reviewAtCurrentRevisionAccepted() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let agg = try await rig.repo.applyLifecyclePlan(
            runID: runID, expectedRevision: rev,
            plan: reviewPlan(contentChanged: false, reviewedContentRevision: cr), now: t0)
        #expect(agg.reviews.count == 1)
        #expect(agg.reviews[0].reviewedContentRevision == cr)
    }

    @Test("A content-changing (reopen) plan requires the review at current+1, not current")
    func reopenReviewMustBeCurrentPlusOne() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        // current (cr) is wrong for a content-changing plan — the effective revision is cr+1.
        await #expect(throws: MethodPersistenceError.reviewEpochMismatch(runID: runID, expected: cr + 1, actual: cr)) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev,
                plan: self.reviewPlan(contentChanged: true, reviewedContentRevision: cr), now: self.t0)
        }
        // cr+1 is accepted, and the content revision advances to cr+1.
        let agg = try await rig.repo.applyLifecyclePlan(
            runID: runID, expectedRevision: rev,
            plan: reviewPlan(contentChanged: true, reviewedContentRevision: cr + 1), now: t0)
        #expect(agg.run.contentRevision == cr + 1)
        #expect(agg.reviews[0].reviewedContentRevision == cr + 1)
    }

    // MARK: - Validation batch epoch + integrity

    @Test("A validation batch with the legacy (zero) batch id is rejected")
    func validationBatchRejectsLegacyID() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let row = validationRow(runID: runID, batchID: MethodValidationResult.legacyBatchID, rev: cr)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev, plan: self.validationPlan([row]), now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A validation batch whose rows carry different batch ids is rejected")
    func validationBatchRejectsMixedIDs() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let rows = [validationRow(runID: runID, batchID: UUID(), rev: cr),
                    validationRow(runID: runID, batchID: UUID(), rev: cr)]
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev, plan: self.validationPlan(rows), now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A validation batch evaluating a revision other than the current one is rejected")
    func validationBatchRejectsWrongRevision() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let row = validationRow(runID: runID, batchID: UUID(), rev: cr + 1)
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev, plan: self.validationPlan([row]), now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A validation row belonging to another run is rejected")
    func validationBatchRejectsForeignRow() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let row = validationRow(runID: UUID(), batchID: UUID(), rev: cr)   // foreign run id
        await #expect(throws: MethodPersistenceError.self) {
            _ = try await rig.repo.applyLifecyclePlan(
                runID: runID, expectedRevision: rev, plan: self.validationPlan([row]), now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A single non-legacy batch evaluating the current revision, owned by the run, is accepted")
    func validationBatchAtCurrentRevisionAccepted() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let (runID, rev, cr) = try await seeded(rig)
        let batchID = UUID()
        let rows = [validationRow(runID: runID, batchID: batchID, rev: cr),
                    validationRow(runID: runID, batchID: batchID, rev: cr)]
        let agg = try await rig.repo.applyLifecyclePlan(
            runID: runID, expectedRevision: rev, plan: validationPlan(rows), now: t0)
        #expect(agg.validationResults.count == 2)
        #expect(agg.validationResults.allSatisfy { $0.validationBatchID == batchID && $0.evaluatedContentRevision == cr })
    }
}
