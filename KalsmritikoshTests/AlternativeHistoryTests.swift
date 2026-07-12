//
//  AlternativeHistoryTests.swift
//  KalsmritikoshTests
//
//  A7.3 — AlternativeHistoryBuilder turns detected contradictions into competing
//  accounts with the decisive missing evidence, naming a leading account only
//  when one side is strictly better corroborated. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct AlternativeHistoryTests {

    private func contradiction(_ kind: Contradiction.Kind, a: KnowledgeObject.ID, b: KnowledgeObject.ID) -> Contradiction {
        Contradiction(kind: kind, description: "Conflicting \(kind.rawValue)",
                      claimA: "account A", claimB: "account B", evidenceA: a, evidenceB: b)
    }

    @Test func balancedConflictHasNoLeadingAccount() {
        let alt = AlternativeHistoryBuilder().build(
            contradictions: [contradiction(.date, a: UUID(), b: UUID())]
        )
        #expect(alt.count == 1)
        #expect(alt.first?.accounts.count == 2)
        #expect(alt.first?.isBalanced == true)
        #expect(alt.first?.leadingIndex == nil)
    }

    @Test func betterCorroboratedSideLeads() {
        let a = UUID(), b = UUID()
        let alt = AlternativeHistoryBuilder().build(
            contradictions: [contradiction(.amount, a: a, b: b)],
            corroboration: [a: 3, b: 1]
        )
        #expect(alt.first?.leadingIndex == 0)
        #expect(alt.first?.isBalanced == false)
    }

    @Test func decisiveMissingEvidenceIsKindSpecific() {
        #expect(AlternativeHistoryBuilder.decisiveMissingEvidence(for: .amount).contains("invoice") ||
                AlternativeHistoryBuilder.decisiveMissingEvidence(for: .amount).contains("payment"))
        #expect(AlternativeHistoryBuilder.decisiveMissingEvidence(for: .date).contains("date"))
        #expect(AlternativeHistoryBuilder.decisiveMissingEvidence(for: .signature).contains("signatory"))
    }

    @Test func unresolvedConflictShowsBothSides() {
        let alt = AlternativeHistoryBuilder().build(
            contradictions: [contradiction(.location, a: UUID(), b: UUID())]
        )
        #expect(alt.first?.unresolvedConflict.contains("account A") == true)
        #expect(alt.first?.unresolvedConflict.contains("account B") == true)
    }
}
