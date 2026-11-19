//
//  CaseEntryPointsTests.swift
//  KalsmritikoshTests
//
//  Reachability recheck 2026-11-17 (QA-16) — the 26 tracker rows whose services had no screen now each have one. This
//  pins every service call to a SwiftUI caller (a later edit that drops the screen fails here), and checks the pure
//  helpers the new screens use. The screens themselves are not walked here (that needs the running app).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Entry points for the 26 unreachable services (QA-16)")
struct CaseEntryPointsTests {

    /// Row → the service calls its screen must make (each must appear in Kalsmritikosh/UI or /App).
    static let calls: [(row: String, calls: [String])] = [
        ("IN-06", ["contentEquivalents(of:", "revisionCandidates(for:", "confirmRevision(revised:"]),
        ("REASON-02", ["setEvidenceRelation(caseID:"]),
        ("REASON-03", ["desk.comparison(caseID:"]),
        ("REASON-04", ["decision: .explained"]),
        ("REASON-07", ["createConflictFollowUp(caseID:", "recordFollowUpOutcome(caseID:"]),
        ("REASON-10", ["decisionInputs(caseID:"]),
        ("TIME-03", ["file.times(caseID:", "interpretTime(caseID:"]),
        ("TIME-04", ["file.timeline(caseID:"]),
        ("CHANGE-07", ["queueLateContribution(caseID:", "decideLateContribution(caseID:", "lateContributions(caseID:"]),
        ("PEOPLE-01", ["addPersonOrRole(caseID:", "identityViews(caseID:", "endPersonRole(caseID:"]),
        ("PEOPLE-02", ["addPersonAttribute(caseID:", "personProfile(caseID:", "withdrawPersonAttribute(caseID:"]),
        ("PEOPLE-03", ["recordLocationObservation(caseID:"]),
        ("PEOPLE-04", ["addInterviewItem(caseID:", "correctInterviewItem(caseID:", "statementHistory(caseID:"]),
        ("PEOPLE-06", ["workHistory(caseID:"]),
        ("PEOPLE-08", ["declareCapability(investigator:", "declareUnavailable(investigator:", "routingCandidates(caseID:", "runConflictCheck(caseID:"]),
        ("PEOPLE-09", ["addTeamMember(caseID:", "endTeamMembership(caseID:"]),
        ("MONEY-08", ["recordConversionRate(caseID:", "ledger.converted("]),
        ("MONEY-09", ["recordAccountRelation(caseID:", "withdrawAccountRelation(caseID:"]),
        ("MONEY-11", ["syncMoneyGapProposals(caseID:", "decideMoneyGapProposal(caseID:"]),
        ("HISTORY-03", ["addCrossReference(caseID:", "review.resolve(caseID:"]),
        ("HISTORY-04", ["review.compare(caseID:"]),
        ("HISTORY-05", ["startReview(caseID:", "recordReviewFinding(caseID:", "review.trace(caseID:"]),
        ("HISTORY-06", ["pinAsKnownAt(caseID:", "originKnownAt(caseID:"]),
        ("ACTION-10", ["actionRollup(caseID:"]),
        ("ACTION-12", ["proposeReopenings(caseID:", "decideReopening(caseID:"]),
        ("OUTPUT-09", ["recordClosurePosition(caseID:", "closurePositions(caseID:"]),
    ]

    @Test("Each of the 26 rows' services is called from a screen")
    func everyRowHasAScreen() {
        #expect(Self.calls.count == 26)
        let ui = HelpRegistryTests.uiSources
        for (row, calls) in Self.calls {
            for c in calls { #expect(ui.contains(c), "\(row): no screen calls \(c)") }
        }
    }

    @Test("The new tools are in Case tools, each with its purpose and an empty state that names one next action")
    func toolsListed() {
        for t in [CaseMapTool.casePeople, .team, .closing] {
            #expect(CaseMapTool.allCases.contains(t) && t.purpose.count > 40 && HelpRegistry.topic(t.helpTopic) != nil, "\(t)")
        }
        for c in ["Add person or role", "Record observation", "Correct this answer…", "End membership…", "Record closure position", "Record late material",
                  "Check finished work against newer evidence", "Record rate", "Record relationship", "Check for gaps", "Compare with this case",
                  "Start a review of this case", "Use this time", "Create follow-up action", "Confirm as a revision"] {
            #expect(CaseMapControlHelp.entry(c) != nil, "no help for \(c)")
        }
    }

    @Test("Waived work is read as item — reason; a line without a reason is refused, not guessed")
    @MainActor
    func waivedWorkLines() {
        let w = CaseMapClosingTool.waivedWork("Interview the courier — left the country\n\nBank B statements — not held by the bank")
        #expect(w == [CaseWaivedWork(item: "Interview the courier", reason: "left the country"),
                      CaseWaivedWork(item: "Bank B statements", reason: "not held by the bank")])
        #expect(CaseMapClosingTool.waivedWork("Interview the courier") == nil)
        #expect(CaseMapClosingTool.waivedWork("") == [])
    }

    @Test("What was known then: before the baseline and before the first recorded state are said, not shown as empty")
    @MainActor
    func knownAtLines() {
        let b = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CaseHistoryReviewBlock.knownLine(.notRecorded(baseline: b)).hasPrefix("Nothing was recorded then"))
        #expect(CaseHistoryReviewBlock.knownLine(.noRecordedStateYet(baseline: b)).hasPrefix("No state of that case was recorded yet"))
    }

    @Test("Money gaps are named in plain words")
    @MainActor
    func gapLabels() {
        #expect(CaseMoneyMoreBlock.kindLabel(.missingStatement) == "Missing statement")
        #expect(Set(CaseMoneyGapProposal.Kind.allCases.map(CaseMoneyMoreBlock.kindLabel)).count == CaseMoneyGapProposal.Kind.allCases.count)
    }
}
