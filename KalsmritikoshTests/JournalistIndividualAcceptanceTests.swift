//
//  JournalistIndividualAcceptanceTests.swift
//  KalsmritikoshTests
//
//  Journalist and Individual persona acceptance through the REAL production PersonaJobService path, via the
//  shared PersonaAcceptanceHarness. Each persona's matter is driven fully: discover → enumerate → intake
//  creates a real matter → authorize source → EVERY job routes into a real shared service → package/edition
//  build (unauthorized source excluded) → human approval → no auto-close → close → reopen. Simple/Advanced
//  route to the same shared destinations. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Journalist persona acceptance (production path)", .serialized)
struct JournalistPersonaAcceptanceTests {
    static let stories = ["contract award", "safety recall", "campaign finance", "public appointment", "supply chain"]
    private let t0 = Date(timeIntervalSince1970: 1_768_700_000)

    @Test("Each story processes through the production PersonaJobService path — all 14 jobs route real",
          arguments: JournalistPersonaAcceptanceTests.stories)
    func storyThroughProductionPath(_ story: String) async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: story)
        try await h.runFullPersonaMatter(
            personaID: JournalistPersonaPackage.applicationID, expectedJobCount: 14, intakeJobID: "jrn.story-intake",
            template: .journalism, title: story, actor: "reporter", at: t0)
    }

    @Test("Simple and Advanced route the Journalist persona to the SAME shared destinations")
    func simpleAdvancedIdentical() throws {
        for surface in ShellSurface.allCases {
            #expect(ShellRouter.route(template: .journalism, mode: .simple, surface: surface).destination
                    == ShellRouter.route(template: .journalism, mode: .advanced, surface: surface).destination)
        }
    }
}

@Suite("Individual persona acceptance (production path)", .serialized)
struct IndividualPersonaAcceptanceTests {
    static let matters = ["home purchase", "insurance claim", "family history", "job application", "estate planning"]
    private let t0 = Date(timeIntervalSince1970: 1_768_800_000)

    @Test("Each personal matter processes through the production PersonaJobService path — all 13 jobs route real",
          arguments: IndividualPersonaAcceptanceTests.matters)
    func matterThroughProductionPath(_ matter: String) async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: matter)
        try await h.runFullPersonaMatter(
            personaID: IndividualPersonaPackage.applicationID, expectedJobCount: 13, intakeJobID: "ind.personal-records",
            template: .personalMatter, title: matter, actor: "owner", at: t0)
    }

    @Test("Simple and Advanced route the Individual persona to the SAME shared destinations")
    func simpleAdvancedIdentical() throws {
        for surface in ShellSurface.allCases {
            #expect(ShellRouter.route(template: .personalMatter, mode: .simple, surface: surface).destination
                    == ShellRouter.route(template: .personalMatter, mode: .advanced, surface: surface).destination)
        }
    }

    @Test("All four shipped personas are discoverable in the ONE production catalog")
    func fourPersonasDiscoverable() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        for id in [InvestigatorPersonaPackage.applicationID, ResearcherPersonaPackage.applicationID,
                   JournalistPersonaPackage.applicationID, IndividualPersonaPackage.applicationID] {
            #expect(catalog.latestApplication(id: id) != nil)
        }
        #expect(PersonaJobCatalogComposer.jobs(forPersona: JournalistPersonaPackage.applicationID).count == 14)
        #expect(PersonaJobCatalogComposer.jobs(forPersona: IndividualPersonaPackage.applicationID).count == 13)
    }
}
