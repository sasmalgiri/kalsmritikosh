//
//  HumanConfirmedStatusTests.swift
//  KalsmritikoshTests
//
//  A5.5 — reviewer affirmations become .humanConfirmed, never .proven. A person
//  vouching for a fact is not the same as it being structurally proven. Add to
//  the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct HumanConfirmedStatusTests {

    private func item() -> FactStatusItem {
        FactStatusItem(status: .inferred, title: "Meeting held", reason: "inferred",
                       confidence: 0.6, sourceKind: .event)
    }

    private func review(_ action: FactReview.Action) -> FactReview {
        FactReview(subjectKind: .event, subjectID: UUID(), action: action, reviewer: "you")
    }

    @Test func acceptBecomesHumanConfirmedNotProven() {
        let out = FactStatusClassifier.applyReview(item(), review(.accept))
        #expect(out.status == .humanConfirmed)
        #expect(out.status != .proven)
    }

    @Test func correctiveActionsAreHumanConfirmed() {
        for action in [FactReview.Action.correct, .merge, .split, .precisionChange, .resolveContradiction, .markAuthority] {
            #expect(FactStatusClassifier.applyReview(item(), review(action)).status == .humanConfirmed)
        }
    }

    @Test func rejectIsUnverifiedNotHumanConfirmed() {
        #expect(FactStatusClassifier.applyReview(item(), review(.reject)).status == .unverified)
    }

    @Test func humanConfirmedLabelIsDistinctFromProven() {
        #expect(FactStatus.humanConfirmed.displayName != FactStatus.proven.displayName)
        #expect(FactStatus.humanConfirmed.displayName == "Confirmed by you")
    }
}
