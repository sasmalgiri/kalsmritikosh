//
//  PersonaPolicyTests.swift
//  KalsmritikoshTests
//
//  PER-001 — persona policies exist for every persona and control presentation only. The
//  truth invariant is structural: the policy type carries no field that changes evidence,
//  truth state, confidence or independence.
//

import Testing
@testable import Kalsmritikosh

@Suite("PER-001 PersonaPolicy")
struct PersonaPolicyTests {

    @Test("Every persona has a policy")
    func totalCoverage() {
        for t in WorkspaceTemplate.allCases {
            let p = PersonaPolicyRegistry.policy(for: t)
            #expect(p.template == t)
            #expect(p.version == PersonaPolicyRegistry.version)
            #expect(!p.subjectNoun.isEmpty)
        }
    }

    @Test("Personas differ in presentation defaults, not truth")
    func presentationDiffers() {
        let legal = PersonaPolicyRegistry.policy(for: .legalMatter)
        let research = PersonaPolicyRegistry.policy(for: .researchReview)
        #expect(legal.citationStyle == .legalPin)
        #expect(research.citationStyle == .bibliographic)
        #expect(legal.requiresCorroboration)
        #expect(!research.requiresCorroboration)
    }

    @Test("Investigation warns that a missing record is not proof of wrongdoing")
    func investigationWarning() {
        let inv = PersonaPolicyRegistry.policy(for: .investigation)
        #expect(inv.reviewWarnings.contains { $0.lowercased().contains("not proof") })
        #expect(inv.redactByDefault)
    }

    @Test("Truth invariant: policy exposes no evidence/confidence/independence knob")
    func truthInvariant() {
        // Compile-time guarantee expressed as a value check: the policy only holds
        // presentation/workflow fields. If someone adds a truth knob later, they must update
        // this test — a deliberate tripwire.
        let mirror = Mirror(reflecting: PersonaPolicyRegistry.policy(for: .general))
        let fields = Set(mirror.children.compactMap { $0.label })
        let forbidden: Set<String> = ["confidence", "evidenceStatus", "truth", "isIndependent", "weight"]
        #expect(fields.isDisjoint(with: forbidden))
    }
}
