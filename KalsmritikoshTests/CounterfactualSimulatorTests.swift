//
//  CounterfactualSimulatorTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("CounterfactualSimulator — Vol 09 §Counterfactual")
struct CounterfactualSimulatorTests {
    /// Builds a small 4-node graph: E1 → E2 → E3 + E2 → E4.
    /// Preventing E1 should reach E2/E3/E4. Preventing E2 should
    /// reach E3/E4. Preventing E4 should reach nothing.
    @Test("reachability over a forward causal chain")
    func reachabilityForward() {
        let e1 = Event(kind: .other, date: Date(), title: "E1", sourceObjectID: UUID())
        let e2 = Event(kind: .other, date: Date(), title: "E2", sourceObjectID: UUID())
        let e3 = Event(kind: .other, date: Date(), title: "E3", sourceObjectID: UUID())
        let e4 = Event(kind: .other, date: Date(), title: "E4", sourceObjectID: UUID())
        let links = [
            CausalLink(sourceEventID: e1.id, targetEventID: e2.id, relation: .caused, confidence: 0.9),
            CausalLink(sourceEventID: e2.id, targetEventID: e3.id, relation: .caused, confidence: 0.8),
            CausalLink(sourceEventID: e2.id, targetEventID: e4.id, relation: .enabled, confidence: 0.6)
        ]
        let sim = CounterfactualSimulator()
        let fromE1 = sim.simulate(preventedEventID: e1.id, links: links, events: [e1, e2, e3, e4])
        #expect(Set(fromE1.map(\.targetEventID)) == Set([e2.id, e3.id, e4.id]))
        let fromE2 = sim.simulate(preventedEventID: e2.id, links: links, events: [e1, e2, e3, e4])
        #expect(Set(fromE2.map(\.targetEventID)) == Set([e3.id, e4.id]))
        let fromE4 = sim.simulate(preventedEventID: e4.id, links: links, events: [e1, e2, e3, e4])
        #expect(fromE4.isEmpty)
    }

    @Test("PREVENTED edges are skipped (no counterfactual composition)")
    func preventedEdgesSkipped() {
        let a = Event(kind: .other, date: Date(), title: "A", sourceObjectID: UUID())
        let b = Event(kind: .other, date: Date(), title: "B", sourceObjectID: UUID())
        let links = [
            CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .prevented, confidence: 0.9)
        ]
        let sim = CounterfactualSimulator()
        let impacts = sim.simulate(preventedEventID: a.id, links: links, events: [a, b])
        #expect(impacts.isEmpty)
    }

    @Test("FOLLOWED edges are skipped (temporal-only, not causal)")
    func followedEdgesSkipped() {
        let a = Event(kind: .other, date: Date(), title: "A", sourceObjectID: UUID())
        let b = Event(kind: .other, date: Date(), title: "B", sourceObjectID: UUID())
        let links = [
            CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .followed, confidence: 0.5)
        ]
        let sim = CounterfactualSimulator()
        let impacts = sim.simulate(preventedEventID: a.id, links: links, events: [a, b])
        #expect(impacts.isEmpty)
    }
}
