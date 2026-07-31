//
//  MethodLifecycleStateMachineTests.swift
//  KalsmritikoshTests
//
//  PM-004 — the closed lifecycle state machine: every allowed transition resolves,
//  and undeclared transitions (incl. from terminal states) fail closed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — MethodLifecycleStateMachine")
struct MethodLifecycleStateMachineTests {

    private func target(_ from: MethodRunStatus, _ action: MethodLifecycleUserAction) -> MethodRunStatus? {
        MethodLifecycleStateMachine.target(from: from, action: action)
    }

    @Test("draft: start → active") func draftStart() { #expect(target(.draft, .start) == .active) }
    @Test("active: pause → paused") func activePause() { #expect(target(.active, .pause) == .paused) }
    @Test("paused: resume → active") func pausedResume() { #expect(target(.paused, .resume) == .active) }
    @Test("active: requestHumanReview → waitingForHuman") func activeReviewRequest() {
        #expect(target(.active, .requestHumanReview) == .waitingForHuman)
    }
    @Test("waitingForHuman: continueAfterReview → active") func waitingContinue() {
        #expect(target(.waitingForHuman, .continueAfterReview) == .active)
    }
    @Test("active: block → blocked") func activeBlock() { #expect(target(.active, .block) == .blocked) }
    @Test("waitingForHuman: block → blocked") func waitingBlock() { #expect(target(.waitingForHuman, .block) == .blocked) }
    @Test("blocked: unblock → active") func blockedUnblock() { #expect(target(.blocked, .unblock) == .active) }
    @Test("active: complete → completed") func activeComplete() { #expect(target(.active, .complete) == .completed) }
    @Test("completed: reopen → active") func completedReopen() { #expect(target(.completed, .reopen) == .active) }

    @Test("cancel is allowed from every non-terminal status") func cancelPaths() {
        for s in [MethodRunStatus.draft, .active, .paused, .waitingForHuman, .blocked] {
            #expect(target(s, .cancel) == .cancelled, "\(s)")
        }
        #expect(target(.completed, .cancel) == nil)   // completed is not cancellable (reopen/supersede only)
    }

    @Test("supersede is allowed from every status except cancelled/superseded") func supersedePaths() {
        for s in [MethodRunStatus.draft, .active, .paused, .waitingForHuman, .blocked, .completed] {
            #expect(target(s, .supersede) == .superseded, "\(s)")
        }
    }

    @Test("cancelled is terminal — no outgoing transition") func cancelledTerminal() {
        for a in MethodLifecycleUserAction.allCases { #expect(target(.cancelled, a) == nil, "\(a)") }
        #expect(MethodRunStatus.cancelled.isTerminal)
    }

    @Test("superseded is terminal — no outgoing transition") func supersededTerminal() {
        for a in MethodLifecycleUserAction.allCases { #expect(target(.superseded, a) == nil, "\(a)") }
        #expect(MethodRunStatus.superseded.isTerminal)
    }

    @Test("representative undeclared transitions fail closed") func deniedTransitions() {
        #expect(target(.draft, .pause) == nil)
        #expect(target(.draft, .complete) == nil)
        #expect(target(.paused, .complete) == nil)
        #expect(target(.blocked, .complete) == nil)
        #expect(target(.active, .resume) == nil)
        #expect(target(.active, .unblock) == nil)
        #expect(target(.active, .continueAfterReview) == nil)
        #expect(target(.completed, .complete) == nil)
    }
}
