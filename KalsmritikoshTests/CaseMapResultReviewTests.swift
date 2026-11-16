//
//  CaseMapResultReviewTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (ACTION-13): the map's Accept / Return go through the versioned result review whenever the action
//  has a recorded result version (exact revision, reviewer, rationale; a later revision needs review again), and record
//  the rationale on the action when its result exists only as a result report.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Map result review — the exact result version, with a rationale")
struct CaseMapResultReviewTests {

    @Test("With a result version: Accept pins that revision; a new revision needs review again")
    func versionedReview() async throws {
        let f = try await CaseFileTests.fixture(title: "Was the seal intact?")
        let v = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "lab-note.txt", text: "The seal was intact.").version
        let t = try await f.svc.createAction(caseID: f.caseID, .init(title: "Check the seal", purpose: "p", deliverable: "d"), actor: "Ada")
        _ = try await f.file.recordActionResult(caseID: f.caseID, taskID: t, kind: .report, outcome: .successful, summary: "Seal intact",
                                                inputs: [.source(v, "lab note")], actor: "Ada")
        try await f.file.submitAction(caseID: f.caseID, taskID: t, note: nil, actor: "Ada")
        let kind = try await CaseMapWorkCommands.reviewResult(f.svc, caseID: f.caseID, taskID: t, accept: true, rationale: "Photo matches the note", actor: "Ada")
        #expect(kind == .selfReview)
        let reviews = try await f.file.actionResultReviews(caseID: f.caseID)
        #expect(reviews.contains { $0.taskID == t && $0.revision == 1 && $0.rationale == "Photo matches the note" })
        #expect(try await f.file.reportLedger(caseID: f.caseID).contract(t)?.review == .accepted)
        // A new version after acceptance needs review again.
        _ = try await f.file.recordActionResult(caseID: f.caseID, taskID: t, kind: .report, outcome: .successful, summary: "Seal intact; second photo",
                                                inputs: [.source(v, "lab note")], actor: "Ada")
        #expect(try await f.file.reReviewNeeded(caseID: f.caseID).contains { $0.taskID == t })
    }

    @Test("Without a result version (a result report only): the decision and its rationale are recorded on the action")
    func reportOnlyReview() async throws {
        let f = try await CaseFileTests.fixture(title: "Was the seal intact?")
        let t = try await f.svc.createAction(caseID: f.caseID, .init(title: "Check the seal", purpose: "p", deliverable: "d"), actor: "Ada")
        try await f.file.submitAction(caseID: f.caseID, taskID: t, note: nil, actor: "Ada")
        _ = try await CaseMapWorkCommands.reviewResult(f.svc, caseID: f.caseID, taskID: t, accept: false, rationale: "Attach the photo", actor: "Ada")
        let k = try #require(try await f.file.reportLedger(caseID: f.caseID).contract(t))
        #expect(k.review == .returned)
        #expect(try await f.file.actionResultReviews(caseID: f.caseID).isEmpty)
    }
}
