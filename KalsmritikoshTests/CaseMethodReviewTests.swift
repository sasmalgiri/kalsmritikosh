//
//  CaseMethodReviewTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (REASON-14): the 16-method applicability review — every registered method accounted for, with
//  no contradiction needed to start; completed work reused; unfinished work continued; an unknown method is "not
//  assessed", never omitted; deterministic and offline.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Method applicability review — all 16 accounted for")
struct CaseMethodReviewTests {

    /// A supplier-quality case with documents, people and dates, but no contradiction and one explanation.
    private func quietCase() -> CaseMethodReviewInput {
        var c = CaseMethodReviewInput()
        c.question = "Why did batch 42 fail the assay?"
        c.documents = 12
        c.people = 3
        c.datedEvents = 5
        c.openExplanations = 1
        return c
    }

    @Test("With no contradiction and AI off, all 16 registered methods get an outcome with a reason, and some are useful now")
    func allSixteenWithoutAContradiction() {
        let methods = CaseMethodReviewMethod.registered
        #expect(methods.count == 16)
        let r = CaseMethodReview.assess(methods: methods, input: quietCase())
        #expect(r.accountsFor(methods))
        #expect(!r.assessments.contains { $0.outcome == .notAssessed }, "\(r.assessments.filter { $0.outcome == .notAssessed }.map(\.methodID))")
        #expect(r.assessments.allSatisfy { !$0.reason.isEmpty && !$0.contributes.isEmpty })
        let now = Set(r.shortlist.map(\.methodID))
        #expect(now.contains("com.kalsmritikosh.method.brainstorming"), "one explanation only: brainstorm alternatives")
        #expect(now.contains("com.kalsmritikosh.method.five-whys") && now.contains("com.kalsmritikosh.method.timeline-analysis"))
        #expect(!now.contains("com.kalsmritikosh.method.capa"), "corrective action is premature without a reviewed cause")
        let byID = Dictionary(uniqueKeysWithValues: r.assessments.map { ($0.methodID, $0) })
        #expect(byID["com.kalsmritikosh.method.transaction-flow"]?.outcome == .inapplicable)
        #expect(byID["com.kalsmritikosh.method.effectiveness-review"]?.outcome == .inapplicable)
        #expect(byID["com.kalsmritikosh.method.hypothesis-matrix"]?.outcome == .needsInput)
        // Deterministic: the same case state gives the same review.
        #expect(CaseMethodReview.assess(methods: methods, input: quietCase()) == r)
    }

    @Test("A completed run at this version is reused as already covered; an unfinished one is continued; superseded runs are ignored")
    func existingWorkReused() {
        let methods = CaseMethodReviewMethod.registered
        let fishbone = try! #require(methods.first { $0.id.hasSuffix(".fishbone") })
        let whys = try! #require(methods.first { $0.id.hasSuffix(".five-whys") })
        let brainstorm = try! #require(methods.first { $0.id.hasSuffix(".brainstorming") })
        var c = quietCase()
        let done = UUID(), open = UUID()
        c.runs = [
            .init(id: done, methodID: fishbone.id, methodVersion: fishbone.version, status: .completed, contentRevision: 4),
            .init(id: open, methodID: whys.id, methodVersion: whys.version, status: .active, contentRevision: 2),
            .init(id: UUID(), methodID: brainstorm.id, methodVersion: brainstorm.version, status: .superseded, contentRevision: 1),
            .init(id: UUID(), methodID: brainstorm.id, methodVersion: brainstorm.version + 1, status: .completed, contentRevision: 1),
        ]
        let byID = Dictionary(uniqueKeysWithValues: CaseMethodReview.assess(methods: methods, input: c).assessments.map { ($0.methodID, $0) })
        #expect(byID[fishbone.id]?.outcome == .alreadyCovered && byID[fishbone.id]?.priorRunID == done)
        #expect(byID[whys.id]?.outcome == .usefulNow && byID[whys.id]?.priorRunID == open && byID[whys.id]?.reason.contains("continue") == true)
        #expect(byID[brainstorm.id]?.outcome == .usefulNow && byID[brainstorm.id]?.priorRunID == nil, "superseded and other-version runs do not count")
    }

    @Test("A method this build has no guidance for is 'not assessed', and still accounted for")
    func unknownMethodNotAssessed() {
        let methods = CaseMethodReviewMethod.registered + [CaseMethodReviewMethod(id: "com.example.method.new", version: 1, label: "New method")]
        let r = CaseMethodReview.assess(methods: methods, input: quietCase())
        #expect(r.accountsFor(methods))
        #expect(r.assessments.last?.outcome == .notAssessed)
    }

    @Test("From a real case: the documents, people, dated events, money and the case's own method runs feed the review")
    func inputFromTheCase() async throws {
        let f = try await CaseFileTests.fixture(title: "Why did batch 42 fail?")
        var custody: [CustodyManifestEntry] = []
        for (name, text) in [("lab-report.txt", "Batch 42 failed the assay on 3 March 2026."), ("supplier-cert.txt", "The supplier certified the material.")] {
            let v = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: name, text: text).version
            custody.append(CustodyManifestEntry(sourceVersionID: v, contentHash: nil, custodyEvents: []))
        }
        _ = try await f.file.addPerson(caseID: f.caseID, name: "Ravi Kumar", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Assay failed", eventDate: Date(timeIntervalSince1970: 1_772_496_000),
                                        evidenceRef: nil, actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "A note, not an event", eventDate: nil, evidenceRef: nil, actor: "Ada")
        let whys = try #require(CaseMethodReviewMethod.registered.first { $0.id.hasSuffix(".five-whys") })
        let repo = MethodRunRepository(database: f.db)
        let run = try await repo.createRun(workspaceID: f.workspaceID, methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: whys.id),
                                           methodDefinitionVersion: whys.version, title: "Why", createdBy: "Ada", now: Date())
        try await repo.linkCase(f.caseID, methodRunID: run.id, phaseKind: .methods, at: Date())
        let runs = try await repo.runs(caseID: f.caseID)
        #expect(runs.map(\.id) == [run.id])
        let snapshot = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: custody))
        let input = CaseMethodReviewInput.from(question: "Why did batch 42 fail?", snapshot: snapshot, coverage: nil, openContradictions: 1,
                                               money: try await f.file.moneyLedger(caseID: f.caseID), hypotheses: [], requests: [],
                                               runs: runs, now: Date())
        #expect(input.documents == 2 && input.people == 1 && input.datedEvents == 1 && input.openContradictions == 1)
        #expect(input.moneyRecords == 0 && input.runs.count == 1 && input.caseRevision != nil)
        let review = CaseMethodReview.assess(methods: CaseMethodReviewMethod.registered, input: input)
        #expect(review.accountsFor(CaseMethodReviewMethod.registered))
        let byID = Dictionary(uniqueKeysWithValues: review.assessments.map { ($0.methodID, $0) })
        #expect(byID[whys.id]?.priorRunID == run.id && byID[whys.id]?.outcome == .usefulNow, "the case's draft run is the one to continue")
        #expect(byID["com.kalsmritikosh.method.contradiction-matrix"]?.outcome == .usefulNow)
        #expect(byID["com.kalsmritikosh.method.transaction-flow"]?.outcome == .inapplicable)
    }

    @Test("Inputs move the outcomes: no documents needs input; contradictions, money pairs, deadlines and a stated cause make methods useful now")
    func inputsMoveOutcomes() {
        let methods = CaseMethodReviewMethod.registered
        var empty = CaseMethodReviewInput(); empty.question = "Q"
        #expect(CaseMethodReview.assess(methods: methods, input: empty).assessments.allSatisfy { $0.outcome == .needsInput })
        var c = quietCase()
        c.openContradictions = 2; c.moneyRecords = 6; c.undecidedMoneyPairs = 1; c.datedDeadlines = 1
        c.rootCauseStated = true; c.openExplanations = 3; c.missingItems = 1
        let now = Set(CaseMethodReview.assess(methods: methods, input: c).shortlist.map { $0.methodID.replacingOccurrences(of: "com.kalsmritikosh.method.", with: "") })
        for m in ["contradiction-matrix", "transaction-flow", "risk-matrix", "root-cause", "hypothesis-matrix", "decision-matrix", "evidence-collection-plan", "gap-analysis"] {
            #expect(now.contains(m), "\(m) should be useful now")
        }
        #expect(!now.contains("brainstorming"), "three explanations are open")
        c.rootCauseReviewed = true; c.correctiveActions = 2; c.correctiveActionsFollowedUp = 1
        let later = Dictionary(uniqueKeysWithValues: CaseMethodReview.assess(methods: methods, input: c).assessments.map { ($0.methodID.replacingOccurrences(of: "com.kalsmritikosh.method.", with: ""), $0.outcome) })
        #expect(later["capa"] == .usefulNow && later["effectiveness-review"] == .usefulNow && later["fishbone"] == .usefulLater)
    }
}
