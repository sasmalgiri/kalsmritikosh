//
//  LawyerPersonaAcceptanceTests.swift
//  KalsmritikoshTests
//
//  Lawyer / Professional Reviewer persona acceptance through the REAL production PersonaJobService path, via
//  the shared PersonaAcceptanceHarness. Five legal matters are each driven fully: discover → enumerate
//  LAW-01…LAW-14 → intake creates a real matter → authorize source → EVERY job routes into a real shared
//  service → production package build (unauthorized source excluded) → human approval → no auto-close → close
//  → reopen. Privilege / liability / closure remain human decisions (enforced by the human-gated shared
//  services). Simple/Advanced route identically. This also closes the five-persona catalog. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Lawyer persona acceptance (production path)", .serialized)
struct LawyerPersonaAcceptanceTests {
    static let matters = ["breach of contract", "employment dispute", "IP infringement",
                          "regulatory inquiry", "estate litigation"]
    private let t0 = Date(timeIntervalSince1970: 1_768_900_000)

    @Test("Each legal matter processes through the production PersonaJobService path — all 22 jobs route real",
          arguments: LawyerPersonaAcceptanceTests.matters)
    func matterThroughProductionPath(_ matter: String) async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: matter)
        try await h.runFullPersonaMatter(
            personaID: LawyerPersonaPackage.applicationID, expectedJobCount: 22, intakeJobID: "law.matter-intake",
            template: .legalMatter, title: matter, actor: "counsel", at: t0)
    }

    @Test("Simple and Advanced route the Lawyer persona to the SAME shared destinations")
    func simpleAdvancedIdentical() throws {
        for surface in ShellSurface.allCases {
            #expect(ShellRouter.route(template: .legalMatter, mode: .simple, surface: surface).destination
                    == ShellRouter.route(template: .legalMatter, mode: .advanced, surface: surface).destination)
        }
    }

    @Test("All FIVE shipped personas are discoverable in the ONE production catalog with their full job sets")
    func fivePersonasDiscoverable() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        let expected: [(ApplicationDefinitionID, Int)] = [
            (InvestigatorPersonaPackage.applicationID, 16),
            (ResearcherPersonaPackage.applicationID, 20),
            (JournalistPersonaPackage.applicationID, 22),
            (IndividualPersonaPackage.applicationID, 23),
            (LawyerPersonaPackage.applicationID, 22),
        ]
        for (id, count) in expected {
            #expect(catalog.latestApplication(id: id) != nil, "\(id.rawValue) must be discoverable")
            #expect(PersonaJobCatalogComposer.jobs(forPersona: id).count == count, "\(id.rawValue) job count")
        }
        // PJOB-MAX: 16+20+22+23+22 = 103 launchable jobs across the five shipped personas.
        let total = expected.reduce(0) { $0 + PersonaJobCatalogComposer.jobs(forPersona: $1.0).count }
        #expect(total == 103)
        // Every job across every persona carries a valid persona-neutral kind (routable by PersonaJobService).
        for (id, _) in expected {
            for job in PersonaJobCatalogComposer.jobs(forPersona: id) {
                #expect(PersonaJobKind.allCases.contains(job.kind))
                #expect(job.persona == id.rawValue)
            }
        }
    }
}
