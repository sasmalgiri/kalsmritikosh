//
//  CausalContradictionTests.swift
//  KalsmritikoshTests
//
//  A5.6 — ContradictionDetector.detectCausalConflicts: two independent sources
//  asserting incompatible cause-and-effect between the same events. Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct CausalContradictionTests {

    private func link(_ from: UUID, _ to: UUID, _ rel: CausalRelation, src: UUID) -> CausalLink {
        CausalLink(sourceEventID: from, targetEventID: to, relation: rel,
                   confidence: 0.8, evidenceObjectIDs: [src])
    }

    @Test func oppositeDirectionCausationConflicts() {
        let a = UUID(), b = UUID()
        let links = [link(a, b, .caused, src: UUID()), link(b, a, .caused, src: UUID())]
        let found = ContradictionDetector().detectCausalConflicts(links, title: [a: "A", b: "B"])
        #expect(found.count == 1)
        #expect(found.first?.kind == .causation)
    }

    @Test func causedVsPreventedSameDirectionConflicts() {
        let a = UUID(), b = UUID()
        let links = [link(a, b, .caused, src: UUID()), link(a, b, .prevented, src: UUID())]
        let found = ContradictionDetector().detectCausalConflicts(links, title: [a: "A", b: "B"])
        #expect(found.count == 1)
    }

    @Test func sameSourceDoesNotConflict() {
        let a = UUID(), b = UUID(), s = UUID()
        let links = [link(a, b, .caused, src: s), link(b, a, .caused, src: s)]
        #expect(ContradictionDetector().detectCausalConflicts(links, title: [:]).isEmpty)
    }

    @Test func agreeingLinksDoNotConflict() {
        let a = UUID(), b = UUID()
        let links = [link(a, b, .caused, src: UUID()), link(a, b, .contributedTo, src: UUID())]
        // Same direction, both positive causation → agreement, not conflict.
        #expect(ContradictionDetector().detectCausalConflicts(links, title: [:]).isEmpty)
    }

    @Test func oppositeFollowedIsASequenceConflict() {
        let a = UUID(), b = UUID()
        let links = [link(a, b, .followed, src: UUID()), link(b, a, .followed, src: UUID())]
        let found = ContradictionDetector().detectCausalConflicts(links, title: [a: "A", b: "B"])
        #expect(found.count == 1)
        #expect(found.first?.kind == .sequence)
    }
}
