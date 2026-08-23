//
//  ClinicalSutraTests.swift
//  KalsmritikoshTests
//
//  Sūtra step 5 — a second, non-investigation discipline authored as a Sūtra
//  alone must reuse the same engine (surfaces + conformance), proving one engine
//  serves many subjects.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Clinical differential Sutra (step 5)")
struct ClinicalSutraTests {

    @Test("The differential phase reuses the very same ACH matrix as the investigation")
    func reusesACH() {
        let clinical = SutraCompiler.clinicalDifferential()
        let diff = clinical.phases.first { $0.title == "Differential diagnosis" }
        #expect(diff?.method == .ach)
        #expect(diff?.surface == "hypotheses")
        // Same surface the investigation's analysis phase uses → one engine, two subjects.
        let inv = SutraCompiler.shared().phases.first { $0.kind == .analysis }
        #expect(diff?.surface == inv?.surface)
        #expect(diff?.obligations.contains { $0.lowercased().contains("disconfirming") } == true)
        #expect(diff?.prohibitedConclusions.contains { $0.lowercased().contains("absence of evidence") } == true)
    }

    @Test("It's a distinct constitution — clinical vocabulary and report form")
    func distinctConstitution() {
        let c = SutraCompiler.clinicalDifferential()
        #expect(c.id == "sutra.clinical.differential")
        #expect(c.title.contains("differential"))
        #expect(c.reliabilityScale.contains("GRADE"))
        #expect(c.reportSections.contains("Differential (ACH)"))
        #expect(c.phases.contains { $0.title == "Assessment & plan" })
    }

    @Test("Conformance generalizes: a clean clinical run is conformant via the same checker")
    func conformanceGeneralizes() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true,     // a stated certainty (GRADE)
                            openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings])   // assessment signed off
        let r = SutraConformance.verify(run: run, against: SutraCompiler.clinicalDifferential())
        #expect(r.isConformant)
    }
}
