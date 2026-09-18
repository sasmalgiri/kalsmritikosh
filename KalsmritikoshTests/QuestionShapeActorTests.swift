//
//  QuestionShapeActorTests.swift
//  KalsmritikoshTests
//
//  Plan C1 — the `.actor` shape ("who DID X") is distinguished from `.role`
//  ("who IS the X of …") and from the generic pipeline. Both router checkers
//  agree on clear actor questions.
//

import Testing
@testable import Kalsmritikosh

@Suite("Plan C1 — actor question shape")
struct QuestionShapeActorTests {

    private func shape(_ q: String) -> QuestionShape { QuestionShapeRouter.route(q).shape }

    @Test func whoDidActionRoutesToActor() {
        #expect(shape("who has drafted the claims?") == .actor)
        #expect(shape("who filed the FER response?") == .actor)
        #expect(shape("who signed the agreement?") == .actor)
        #expect(shape("who prepared the amendment?") == .actor)
    }

    @Test func whoIsTheRoleStaysRole() {
        #expect(shape("who is the applicant of the patent?") == .role)
    }

    @Test func nonActorWhoDoesNotMisroute() {
        // No action verb → not actor (falls to the safe general pipeline).
        #expect(shape("who was present?") != .actor)
    }

    @Test func bothCheckersAgreeOnClearActor() {
        let routed = QuestionShapeRouter.route("who drafted the claims?")
        #expect(routed.shape == .actor)
        #expect(routed.twinAgreed == true)
    }
}
