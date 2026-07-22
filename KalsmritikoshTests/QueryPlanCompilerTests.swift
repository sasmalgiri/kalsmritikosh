//
//  QueryPlanCompilerTests.swift
//  KalsmritikoshTests
//
//  RET-001 — verifies the query compiler produces the correct requested fields
//  and, critically, the correct PREFERRED SOURCE ROLE authority signal that
//  RET-003's DocumentFitness will consume to replace the density heuristic.
//
//  These are the real-corpus failing cases from the retrieval-authority
//  investigation (project_retrieval_authority): a payment question must prefer
//  a transactional (receipt) source; a person's "where worked" / "experience"
//  question must prefer a biographical (résumé) source — not correspondence.
//

import Testing
@testable import Kalsmritikosh

@Suite("RET-001 QueryPlanCompiler")
struct QueryPlanCompilerTests {

    private let compiler = QueryPlanCompiler()

    private func plan(_ q: String, scope: UserIntent.Scope = .global,
                      cls: LLMQueryClass = .ordinary) -> QueryPlan {
        compiler.compile(
            intent: UserIntent(kind: .factualLookup, scope: scope, rawQuestion: q),
            category: .fact,
            queryClass: cls
        )
    }

    @Test("Payment question requests amount + counterparty and prefers a transactional source")
    func paymentPrefersReceipt() {
        let p = plan("PhonePe payment — to whom and how much was paid?")
        #expect(p.requestedFields.contains(.monetaryAmount))
        #expect(p.requestedFields.contains(.counterparty))
        // "PhonePe" must NOT trigger contactInfo (brand name contains "phone").
        #expect(!p.requestedFields.contains(.contactInfo))
        // Transactional must outrank correspondence.
        #expect(p.preferredSourceRoles.first == .transactional)
    }

    @Test("Employment question prefers a biographical source over correspondence")
    func whereWorkedPrefersResume() {
        let p = plan("Where has Shirshendu Sasmal worked?", scope: .person("Shirshendu Sasmal"))
        #expect(p.requestedFields.contains(.employment))
        #expect(p.preferredSourceRoles.first == .biographical)
        #expect(p.targetSubjects.contains("Shirshendu Sasmal"))
    }

    @Test("A person's research/experience question is biographical, not correspondence")
    func experienceIsBiographical() {
        let p = plan("Summarize Tapas Maity's research experience", scope: .person("Tapas Maity"))
        #expect(p.requestedFields.contains(.employment))
        #expect(p.preferredSourceRoles.first == .biographical)
    }

    @Test("Contract terms prefer a contractual source")
    func termsPreferContract() {
        let p = plan("What were the terms of the agreement?")
        #expect(p.requestedFields.contains(.terms))
        #expect(p.preferredSourceRoles.first == .contractual)
    }

    @Test("Patent-status question prefers an official source")
    func statusPrefersOfficial() {
        let p = plan("When was the patent granted?")
        #expect(p.requestedFields.contains(.status))
        #expect(p.preferredSourceRoles.first == .official)
    }

    @Test("Correspondence is always a fallback role, never the sole authority")
    func correspondenceIsFallback() {
        let p = plan("Where has X worked?", scope: .person("X"))
        #expect(p.preferredSourceRoles.contains(.correspondence))
        #expect(p.preferredSourceRoles.first != .correspondence)
    }

    @Test("Corroboration policy tracks the query class")
    func corroborationTracksClass() {
        #expect(plan("q", cls: .ordinary).evidencePolicy.requiresCorroboration == false)
        #expect(plan("q", cls: .investigation).evidencePolicy.requiresCorroboration == true)
        #expect(plan("q", cls: .investigation).evidencePolicy.minIndependentSources >= 2)
    }
}
