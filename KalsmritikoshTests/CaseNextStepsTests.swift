//
//  CaseNextStepsTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §14: the case's next steps come from what it holds — untriaged intake, no
//  sources, an allegation with no evidence or with nothing checked against it, an unconfirmed
//  statement, an unacknowledged hold — and disappear when the fact behind them changes.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case next steps from observable state")
struct CaseNextStepsTests {

    @Test("Each step follows a fact in the case and goes when the fact changes")
    func stepsFollowState() async throws {
        let f = try await CaseFileTests.fixture()
        func steps() async throws -> [String] {
            let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
            return CaseNextSteps.compute(s).map(\.id)
        }
        // A new case: triage it, add its documents.
        var ids = try await steps()
        #expect(ids.contains("triage") && ids.contains("sources"))

        try await f.file.recordTriage(caseID: f.caseID, CaseTriage(severity: .high, decision: .accept, reason: "credible"), actor: "Ada")
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Shouted at staff", actor: "Ada")
        ids = try await steps()
        #expect(!ids.contains("triage"))
        #expect(ids.contains("grid-\(a)"))                                  // no evidence for or against

        let source = try #require(try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID).first)
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: source, label: nil, stance: .supports, note: nil, actor: "Ada")
        ids = try await steps()
        #expect(!ids.contains("grid-\(a)") && ids.contains("contrary-\(a)"))   // only supporting evidence
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: "note:Rota shows Sam off shift", label: nil,
                                               stance: .contradicts, note: nil, actor: "Ada")
        #expect(try await !steps().contains("contrary-\(a)"))

        let p = try await f.file.addPerson(caseID: f.caseID, name: "Sam Witness", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let iv = try await f.file.addInterview(caseID: f.caseID, personID: p, questions: nil, actor: "Ada")
        var interview = try #require(try await f.file.interview(id: iv))
        interview.statementText = "I heard shouting."
        try await f.file.updateInterview(interview, actor: "Ada")
        #expect(try await steps().contains("attest-\(iv)"))
        try await f.file.attest(interviewID: iv, caseID: f.caseID, attestedBy: "Sam Witness", actor: "Ada")
        #expect(try await !steps().contains("attest-\(iv)"))

        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Says the shouting was a fire drill.", actor: "Ada")
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two accounts and the rota", actor: "Ada")
        #expect(try await steps().contains("findings"))
        // A failed custody read and broken references lead the list.
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let first = CaseNextSteps.compute(s, unresolvedReferences: 2, custodyReadFailed: true).prefix(2).map(\.id)
        #expect(first == ["custody", "refs"])
    }
}
