//
//  MethodReviewGateTests.swift
//  KalsmritikoshTests
//
//  PM-004 — definition-keyed, human-only review gates evaluated at the exact
//  current content revision: latest-decision-wins, comments ignored, prior-content
//  and legacy reviews stale, and the waiting-continuation gate.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — method review gate", .serialized)
struct MethodReviewGateTests {

    private let t0 = PM004Fixtures.t0

    private func twoReviewDefinition() -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: PM004Fixtures.methodDefID), version: 1, label: "Two reviews",
            category: .causal,
            requiredInputRoles: [MethodInputRole(rawValue: "problemStatement")],
            allowedNodeKinds: [MethodNodeKind(rawValue: "cause")],
            allowedEdgeKinds: [MethodEdgeKind(rawValue: "leadsTo")],
            requiredReviews: [MethodRequiredReview(reviewKey: "final", label: "Final"),
                              MethodRequiredReview(reviewKey: "secondary", label: "Second")],
            validationIdentifiers: ["v.structure"],
            outputContract: MethodOutputContract(allowedFindingKinds: [MethodFindingKind(rawValue: "candidateCause")]))
    }

    @Test("Only a human may record a review; an unknown review key is rejected")
    func humanAndKnownKey() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        await #expect(throws: ProfessionalMethodLifecycleError.humanActorRequired) {
            _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
                action: .acceptForWorkflow, comment: nil, actor: .system, now: self.t0)
        }
        await #expect(throws: ProfessionalMethodLifecycleError.unknownReviewKey("ghost")) {
            _ = try await rig.engine.recordReview(runID: runID, reviewKey: "ghost", nodeID: nil, findingID: nil,
                action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: self.t0)
        }
    }

    @Test("A review is stamped at the current content revision")
    func reviewStampedAtCurrentRevision() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        let run = try #require(try await rig.repo.run(id: runID))
        let agg = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: t0)
        let review = try #require(agg.reviews.first { $0.reviewKey == "final" })
        #expect(review.reviewedContentRevision == run.contentRevision)
        #expect(review.actorKind == .human)
    }

    @Test("The .reopen action cannot be recorded through recordReview")
    func reopenActionRejected() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
                action: .reopen, comment: nil, actor: .human("r"), now: self.t0)
        }
    }

    @Test("Acceptance satisfies the gate; the latest decision wins over an earlier reject")
    func latestAcceptanceWins() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.requestHumanReview(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .reject, comment: nil, actor: .human("r"), now: t0.addingTimeInterval(1))
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: t0.addingTimeInterval(2))
        let agg = try await rig.engine.continueAfterReview(runID: runID, actor: .human("a"), now: t0.addingTimeInterval(3))
        #expect(agg.run.status == .active)
    }

    @Test("A rejection and a revision-request each block continuation")
    func rejectionAndRevisionBlock() async throws {
        let rigReject = try await PM004Fixtures.makeRig()
        let r1 = try await PM004Fixtures.seedRun(rigReject)
        _ = try await rigReject.engine.requestHumanReview(runID: r1, actor: .human("a"), now: t0)
        _ = try await rigReject.engine.recordReview(runID: r1, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .reject, comment: nil, actor: .human("r"), now: t0.addingTimeInterval(1))
        await #expect(throws: ProfessionalMethodLifecycleError.reviewRejected("final")) {
            _ = try await rigReject.engine.continueAfterReview(runID: r1, actor: .human("a"), now: self.t0.addingTimeInterval(2))
        }
        let rigRev = try await PM004Fixtures.makeRig()
        let r2 = try await PM004Fixtures.seedRun(rigRev)
        _ = try await rigRev.engine.requestHumanReview(runID: r2, actor: .human("a"), now: t0)
        _ = try await rigRev.engine.recordReview(runID: r2, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .requestRevision, comment: nil, actor: .human("r"), now: t0.addingTimeInterval(1))
        await #expect(throws: ProfessionalMethodLifecycleError.reviewRevisionRequested("final")) {
            _ = try await rigRev.engine.continueAfterReview(runID: r2, actor: .human("a"), now: self.t0.addingTimeInterval(2))
        }
    }

    @Test("A comment does not satisfy a required review")
    func commentDoesNotSatisfy() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.requestHumanReview(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .comment, comment: "looks close", actor: .human("r"), now: t0.addingTimeInterval(1))
        await #expect(throws: ProfessionalMethodLifecycleError.requiredReviewMissing("final")) {
            _ = try await rig.engine.continueAfterReview(runID: runID, actor: .human("a"), now: self.t0.addingTimeInterval(2))
        }
    }

    @Test("Every required review key must be accepted")
    func allRequiredKeysNeeded() async throws {
        let rig = try await PM004Fixtures.makeRig(definitions: [twoReviewDefinition()])
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.requestHumanReview(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: t0.addingTimeInterval(1))
        await #expect(throws: ProfessionalMethodLifecycleError.requiredReviewMissing("secondary")) {
            _ = try await rig.engine.continueAfterReview(runID: runID, actor: .human("a"), now: self.t0.addingTimeInterval(2))
        }
    }

    @Test("A review at a prior content revision is stale")
    func priorContentReviewStale() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("r"), now: t0)
        // Add content → content revision advances → the review no longer applies.
        let rev = try await PM004Fixtures.revision(rig, runID)
        _ = try await rig.repo.addNode(MethodNode(methodRunID: runID, nodeDefinitionKey: "k2",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "x", ordinal: 1, createdAt: t0, updatedAt: t0),
            expectedRevision: rev, now: t0)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.requiredReviewMissing("final")) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("A legacy unkeyed review never satisfies a required review")
    func legacyReviewStale() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        // Insert a legacy review directly (as a v79 migration would leave it).
        let run = try #require(try await rig.repo.run(id: runID))
        try await rig.db.exec("""
            INSERT INTO method_reviews (id, method_run_id, action, actor_kind, actor_identifier, reviewed_at, review_key, reviewed_content_revision)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(runID), .text("acceptForWorkflow"), .text("human"), .text("legacy"),
                  .real(0), .text("legacy.unkeyed"), .integer(Int64(run.contentRevision))])
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.requiredReviewMissing("final")) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("continueAfterReview is blocked while no review has been recorded")
    func waitingContinuationGate() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.requestHumanReview(runID: runID, actor: .human("a"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.requiredReviewMissing("final")) {
            _ = try await rig.engine.continueAfterReview(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("Reviews persist exactly across a database reopen")
    func reviewPersistsAfterReopen() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: "ok", actor: .human("reviewer-1"), now: t0)
        let db2 = try MigrationFixtureBuilder.reopen(at: rig.url)
        let reviews = try await MethodRunRepository(database: db2).reviews(runID: runID)
        #expect(reviews.count == 1)
        #expect(reviews[0].reviewKey == "final" && reviews[0].action == .acceptForWorkflow)
        #expect(reviews[0].actorIdentifier == "reviewer-1")
    }
}
