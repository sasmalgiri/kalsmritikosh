//
//  SutraTests.swift
//  KalsmritikoshTests
//
//  The compiled constitution (Sūtra step 3) — folds JobToolingCatalog +
//  SutraDoctrine into one inspectable value.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Sutra — the compiled constitution")
struct SutraTests {

    @Test("The shared Sutra has one phase per job-kind, each fully described")
    func shape() {
        let s = SutraCompiler.shared()
        #expect(s.phases.count == PersonaJobKind.allCases.count)
        #expect(s.phases.allSatisfy { !$0.title.isEmpty && !$0.obligations.isEmpty })
        // Every declared surface is a real destination.
        for p in s.phases where p.surface != nil {
            #expect(Destination(rawValue: p.surface!) != nil, "unknown surface \(p.surface!) for \(p.kind)")
        }
        #expect(!s.standardsOfProof.isEmpty)
        #expect(!s.reportSections.isEmpty)
    }

    @Test("The analysis phase carries the ACH doctrine")
    func analysisPhase() {
        let p = try? #require(SutraCompiler.shared().phases.first { $0.kind == .analysis })
        #expect(p?.tier == .analyze)
        #expect(p?.method == .ach)
        #expect(p?.surface == "hypotheses")
        #expect(p?.obligations.contains { $0.lowercased().contains("disprove") } == true)
        #expect(p?.prohibitedConclusions.contains { $0.lowercased().contains("verdict") } == true)
    }

    @Test("Findings reserve the human approval and require a standard of proof")
    func findingsPhase() {
        let p = SutraCompiler.shared().phases.first { $0.kind == .findings }
        #expect(p?.tier == .decideProduce)
        #expect(p?.humanDecisions.contains { $0.lowercased().contains("approve") } == true)
        #expect(p?.obligations.contains { $0.lowercased().contains("standard of proof") } == true)
    }

    @Test("Contradictions must never be averaged away")
    func contradictionDoctrine() {
        let p = SutraCompiler.shared().phases.first { $0.kind == .contradictionGap }
        #expect(p?.prohibitedConclusions.contains { $0.lowercased().contains("average") } == true)
    }

    @Test("A persona lens keeps the shared phases and relabels the title")
    func personaLens() {
        let base = SutraCompiler.shared()
        let inv = SutraCompiler.sutra(forPersonaLabel: "Investigator")
        #expect(inv.title.contains("Investigator"))
        #expect(inv.phases == base.phases)         // same constitution, relabelled
        #expect(inv.phases(inTier: .analyze).count == base.phases(inTier: .analyze).count)
    }
}
