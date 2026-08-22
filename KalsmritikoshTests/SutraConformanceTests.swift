//
//  SutraConformanceTests.swift
//  KalsmritikoshTests
//
//  The constitutional certificate (Sūtra step 4) — a run is conformant only when
//  it met its obligations, made the reserved human decisions, and asserted no
//  prohibited conclusion.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SutraConformance")
struct SutraConformanceTests {

    private let sutra = SutraCompiler.shared()

    @Test("A clean findings run is conformant")
    func clean() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true,
                            openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings])
        let r = SutraConformance.verify(run: run, against: sutra)
        #expect(r.isConformant)
        #expect(r.unmetObligations.isEmpty)
        #expect(r.certificate.contains("Conformant"))
    }

    @Test("Missing standard of proof is an unmet obligation")
    func missingProof() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: false,
                            openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings])
        let r = SutraConformance.verify(run: run, against: sutra)
        #expect(!r.isConformant)
        #expect(r.unmetObligations.contains { $0.lowercased().contains("standard of proof") })
    }

    @Test("Findings reached without approval leaves the human decision pending")
    func approvalPending() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true,
                            openItemsAcknowledged: true,
                            humanDecisionsMade: [])          // not approved
        let r = SutraConformance.verify(run: run, against: sutra)
        #expect(!r.isConformant)
        #expect(r.humanDecisionsPending.contains { $0.lowercased().contains("approve") })
    }

    @Test("An asserted prohibited conclusion fails conformance")
    func prohibited() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true,
                            openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings],
                            assertedProhibited: ["Averaged a conflict"])
        let r = SutraConformance.verify(run: run, against: sutra)
        #expect(!r.isConformant)
        #expect(r.prohibitedAsserted == ["Averaged a conflict"])
        #expect(r.certificate.contains("Prohibited"))
    }
}
