//
//  DisciplineCatalogTests.swift
//  KalsmritikoshTests
//
//  Several disciplines, each authored as a Sūtra alone, all running on one engine.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Built-in disciplines")
struct DisciplineCatalogTests {

    @Test("Four built-in disciplines, uniquely identified, each fully described")
    func catalog() {
        let all = SutraCompiler.builtInDisciplines
        #expect(all.count == 4)
        #expect(Set(all.map(\.id)).count == all.count)
        for d in all {
            #expect(!d.sutra.phases.isEmpty)
            #expect(d.sutra.phases.allSatisfy { !$0.title.isEmpty && !$0.obligations.isEmpty })
            for p in d.sutra.phases where p.surface != nil {
                #expect(Destination(rawValue: p.surface!) != nil, "\(d.id): unknown surface \(p.surface!)")
            }
        }
    }

    @Test("Safety-incident RCA reuses the Reasoning Studio for its causal phase")
    func safetyReusesReasoning() {
        let s = SutraCompiler.safetyIncident()
        let causal = s.phases.first { $0.kind == .causalAnalysis }
        #expect(causal?.surface == "reasoning")
        #expect(causal?.obligations.contains { $0.lowercased().contains("5 whys") || $0.lowercased().contains("fishbone") } == true)
    }

    @Test("Systematic review extracts into the cited-table engine")
    func reviewUsesTable() {
        let s = SutraCompiler.systematicReview()
        let extract = s.phases.first { $0.kind == .dataLab }
        #expect(extract?.method == .table)
        #expect(s.reliabilityScale.contains("GRADE"))
    }

    @Test("Conformance generalizes to every discipline")
    func conformanceEverywhere() {
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true, openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings])
        for d in SutraCompiler.builtInDisciplines {
            #expect(SutraConformance.verify(run: run, against: d.sutra).isConformant, "\(d.id) not conformant")
        }
    }
}
