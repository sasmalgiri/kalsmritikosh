//
//  ShellRoutingTests.swift
//  KalsmritikoshTests
//
//  SHELL-002 — the ONE persona-neutral routing authority. Proves every persona reaches the SAME shared
//  destination for a surface (a persona only decorates labels/emphasis), that Simple and Advanced route
//  to identical destinations over the same state (a mode flip never forks the location), that Ask
//  exposes exactly Fast / Full Evidence, and that a route bridges into the SHELL-001 navigation history.
//  Pure — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-002 — shared routing")
struct ShellRoutingTests {

    private let personas: [WorkspaceTemplate] = [.general, .investigation, .researchReview, .journalism, .personalMatter, .legalMatter]

    @Test("Every surface maps to its shared SHELL-001 destination")
    func surfaceDestinationMapping() {
        #expect(ShellSurface.home.destination == .home)
        #expect(ShellSurface.ask.destination == .answers)
        #expect(ShellSurface.myWork.destination == .jobs)
        #expect(ShellSurface.dataLab.destination == .dataLab)
        #expect(ShellSurface.sources.destination == .sources)
        #expect(ShellSurface.evidence.destination == .evidenceInspector)
        #expect(ShellSurface.reports.destination == .reports)
        #expect(ShellSurface.settings.destination == .settings)
        #expect(ShellSurface.allCases.count == 8)
    }

    @Test("Shared route identity: every persona routes a surface to the SAME destination")
    func sharedRouteIdentity() {
        for surface in ShellSurface.allCases {
            let destinations = Set(personas.map { ShellRouter.route(template: $0, mode: .advanced, surface: surface).destination })
            #expect(destinations.count == 1, "\(surface) forks destination across personas")
            #expect(destinations.first == surface.destination)
        }
    }

    @Test("A persona injects context (labels) without forking the destination")
    func personaContextInjection() {
        let inv = ShellRouter.route(template: .investigation, mode: .advanced, surface: .home)
        let gen = ShellRouter.route(template: .general, mode: .advanced, surface: .home)
        #expect(inv.displayLabel == "Investigation")
        #expect(gen.displayLabel == "Home")
        #expect(inv.destination == gen.destination)   // same shared destination, different label
        let legalWork = ShellRouter.route(template: .legalMatter, mode: .advanced, surface: .myWork)
        #expect(legalWork.displayLabel == "Matter Work")
        #expect(legalWork.destination == ShellSurface.myWork.destination)
    }

    @Test("Simple and Advanced route to the same destination for a shared surface (no forked state)")
    func simpleAdvancedPreservation() {
        for surface in ShellSurface.simpleSurfaces {
            for persona in personas {
                let simple = ShellRouter.route(template: persona, mode: .simple, surface: surface)
                let advanced = ShellRouter.route(template: persona, mode: .advanced, surface: surface)
                #expect(simple.destination == advanced.destination)
                #expect(simple.displayLabel == advanced.displayLabel)
            }
        }
    }

    @Test("Simple offers a strict subset of Advanced's surfaces")
    func simpleSubsetOfAdvanced() {
        let simple = Set(ShellRouter.availableSurfaces(mode: .simple))
        let advanced = Set(ShellRouter.availableSurfaces(mode: .advanced))
        #expect(advanced.isSuperset(of: simple))
        #expect(advanced.count > simple.count)
        #expect(simple == Set([.home, .ask, .myWork, .dataLab, .sources]))
    }

    @Test("Ask exposes exactly Fast and Full Evidence — no older depth names")
    func fastFullOnly() {
        #expect(Set(ShellAnswerMode.allCases.map(\.rawValue)) == ["fast", "fullEvidence"])
        #expect(ShellAnswerMode.fast.displayName == "Fast")
        #expect(ShellAnswerMode.fullEvidence.displayName == "Full Evidence")
    }

    @Test("A persona's default answer mode is a routing preference, not a second engine")
    func personaDefaultAnswerMode() {
        #expect(PersonaRoutingCatalog.context(for: .investigation).defaultAnswerMode == .fullEvidence)
        #expect(PersonaRoutingCatalog.context(for: .personalMatter).defaultAnswerMode == .fast)
    }

    @Test("Recommended surfaces are the persona's emphasis intersected with the mode's available surfaces")
    func recommendedSurfacesIntersectMode() {
        // Investigator recommends evidence, which Simple does not offer → filtered out in Simple.
        let simpleRec = ShellRouter.recommendedSurfaces(template: .investigation, mode: .simple)
        #expect(!simpleRec.contains(.evidence))
        let advancedRec = ShellRouter.recommendedSurfaces(template: .investigation, mode: .advanced)
        #expect(advancedRec.contains(.evidence))
        #expect(Set(simpleRec).isSubset(of: Set(ShellSurface.simpleSurfaces)))
    }

    @Test("A route bridges into the SHELL-001 navigation history, carrying the persona as context")
    func navigationEntryBridge() {
        let route = ShellRouter.route(template: .journalism, mode: .advanced, surface: .sources)
        let entry = ShellRouter.navigationEntry(for: route)
        #expect(entry.destination == route.destination)
        #expect(entry.contextKind == "persona")
        #expect(entry.contextID == WorkspaceTemplate.journalism.rawValue)
        // The entry drives the shared Back/Forward history unchanged.
        var history = AppNavigationHistory()
        history.navigate(to: entry)
        #expect(history.current?.destination == .sources)
    }
}
