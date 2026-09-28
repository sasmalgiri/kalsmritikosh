//
//  CausalLinkPolicyTests.swift
//  KalsmritikoshTests
//
//  U-3 (W-6, unit 1.8) — the answer-reachability gate. Only CAUSED
//  (lexically grounded) and ENABLED (precondition) links may author
//  answers; heuristic CONTRIBUTED_TO / FOLLOWED are advisory. The
//  per-source budget bounds even a dense set. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-3 causal link policy")
struct CausalLinkPolicyTests {

    private func link(_ rel: CausalRelation, _ src: CausalLinkSource,
                      from: Event.ID = UUID(), to: Event.ID = UUID(),
                      conf: Double = 0.7) -> CausalLink {
        CausalLink(sourceEventID: from, targetEventID: to, relation: rel,
                   confidence: conf, evidenceObjectIDs: [], allen: nil, source: src, reason: nil)
    }

    @Test func lexicalCausedReachesAnswers() {
        #expect(CausalLinkPolicy.reachesAnswers(link(.caused, .lexicalTrigger)))
        #expect(CausalLinkPolicy.reachesAnswers(link(.enabled, .heuristic)))
    }

    @Test func heuristicContributedIsAdvisoryOnly() {
        #expect(!CausalLinkPolicy.reachesAnswers(link(.contributedTo, .heuristic)))
        #expect(!CausalLinkPolicy.reachesAnswers(link(.followed, .heuristic)))
        // A CAUSED stamped from a bare heuristic (should never happen, but
        // defend anyway) does NOT reach answers.
        #expect(!CausalLinkPolicy.reachesAnswers(link(.caused, .heuristic)))
    }

    @Test func budgetCapsOutgoingPerSource() {
        let src = UUID()
        let many = (0..<10).map { i in link(.enabled, .heuristic, from: src, conf: Double(i) / 10.0) }
        let bounded = CausalLinkPolicy.boundedForAnswers(many, maxOutgoingPerEvent: 3)
        #expect(bounded.count == 3)
        // Strongest kept.
        #expect(bounded.allSatisfy { $0.confidence >= 0.7 })
    }

    @Test func advisoryCountCountsTheRemainder() {
        let links = [
            link(.caused, .lexicalTrigger),
            link(.contributedTo, .heuristic),
            link(.contributedTo, .heuristic),
            link(.enabled, .heuristic),
        ]
        #expect(CausalLinkPolicy.advisoryCount(links) == 2)
    }
}
