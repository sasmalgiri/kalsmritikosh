//
//  WorkProductBlueprintTests.swift
//  KalsmritikoshTests
//
//  PER-002 — blueprints are data (one per persona), claim-bearing sections require evidence.
//

import Testing
@testable import Kalsmritikosh

@Suite("PER-002 WorkProductBlueprint")
struct WorkProductBlueprintTests {

    @Test("Every persona has at least one sound blueprint")
    func coverage() {
        for p in WorkspaceTemplate.allCases {
            let bps = WorkProductBlueprintRegistry.blueprints(for: p)
            #expect(!bps.isEmpty)
            for bp in bps {
                #expect(bp.persona == p)
                #expect(bp.isSound)
                #expect(!bp.sections.isEmpty)
            }
        }
    }

    @Test("Personas produce distinct default outputs (data, not a code switch)")
    func distinctOutputs() {
        let legal = WorkProductBlueprintRegistry.blueprints(for: .legalMatter).first!
        let journo = WorkProductBlueprintRegistry.blueprints(for: .journalism).first!
        #expect(legal.name != journo.name)
        #expect(legal.sections.map(\.kind) != journo.sections.map(\.kind))
    }

    @Test("Claim-bearing sections require evidence")
    func claimsRequireEvidence() {
        for p in WorkspaceTemplate.allCases {
            for bp in WorkProductBlueprintRegistry.blueprints(for: p) {
                for s in bp.sections where s.requiresEvidence {
                    #expect(s.minEvidencePerClaim >= 1)
                }
            }
        }
    }

    @Test("Journalism requires corroboration (>=2) for its claims/narrative")
    func journalismStrict() {
        let bp = WorkProductBlueprintRegistry.blueprints(for: .journalism).first!
        let claimSections = bp.sections.filter { $0.requiresEvidence }
        #expect(claimSections.allSatisfy { $0.minEvidencePerClaim >= 2 })
    }
}
