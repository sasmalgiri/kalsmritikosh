//
//  InvestigatorDefaultsTests.swift
//  KalsmritikoshTests
//
//  Owner decision 2026-11-03: investigators get search syntax, tags and highlights by default,
//  and the investigation role's own tools are switched on even where DEVONthink has a similar
//  feature. A query typed as plain words keeps the plain search.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite struct InvestigatorDefaultsTests {

    @Test func basicsAreOnByDefaultAndInTheInvestigationRole() {
        for m in ModulePreset.investigatorBasics {
            #expect(m.spec.defaultEnabled, "\(m.rawValue) should default on")
            #expect(m.spec.implemented && !m.spec.preview)
        }
        let investigation = Set(ModulePreset.modules(forPersona: "investigation"))
        #expect(investigation.isSuperset(of: ModulePreset.investigatorBasics))
        // Listed for the role all along, but dropped by the companion rule until now.
        #expect(investigation.contains(.timelineGraph))
    }

    @Test func otherRolesKeepTheCompanionRule() {
        for id in ["legal", "journalism", "research", "devonthink", "general"] {
            #expect(ModulePreset.modules(forPersona: id).allSatisfy { !$0.alsoInDevonthink }, "\(id)")
        }
    }

    @Test func earlierInvestigatorGetsTheRoleToolsOnce() {
        let store = AppDefaults.store
        let keys = ModulePreset.modules(forPersona: "investigation").map { "kalsmritikosh.product.\($0.rawValue)" }
            + [ModulePreset.personaKey, ModulePreset.investigationPresetRevisionKey]
        let saved = keys.map { store.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { store.set(v, forKey: k) } else { store.removeObject(forKey: k) } } }

        // Another role: nothing changes. (Since the 2026-11-06 scope decision the role's tools are the core
        // views — timeline/relationships and dossiers — not specialist tools such as watchlists.)
        store.set("legal", forKey: ModulePreset.personaKey)
        store.removeObject(forKey: ModulePreset.investigationPresetRevisionKey)
        ProductModuleFlags.setEnabled(.timelineGraph, false)
        #expect(!ModulePreset.refreshInvestigationRole(store))
        #expect(!ProductModuleFlags.isEnabled(.timelineGraph))

        // An Investigator from before: the role's tools come on once, including one stored as off.
        store.set("investigation", forKey: ModulePreset.personaKey)
        #expect(ModulePreset.refreshInvestigationRole(store))
        #expect(ProductModuleFlags.isEnabled(.timelineGraph))
        #expect(ProductModuleFlags.isEnabled(.livingDossiers))

        // Afterwards the person's choice stands: turned off, it stays off at the next launch.
        ProductModuleFlags.setEnabled(.timelineGraph, false)
        #expect(!ModulePreset.refreshInvestigationRole(store))
        #expect(!ProductModuleFlags.isEnabled(.timelineGraph))
    }

    @Test func plainWordsAreNotSyntax() {
        for q in ["was invoice 432 paid and delivered", "who signed the contract or the amendment",
                  "not paid", "meeting at 10:30", "Re: invoice", "budget - draft", "-", "*", "John Carter"] {
            #expect(!AdvancedSearchCompiler.usesSyntax(q), "\(q)")
        }
    }

    @Test func syntaxIsRecognised() {
        for q in ["budget AND deadline", "budget OR forecast", "budget NOT draft", "budget NEAR/5 deadline",
                  "budget NEAR deadline", "\"exact phrase\"", "invoice*", "-draft", "type:email", "entity:Carter",
                  "-type:pdf", "(a OR b)", "a && b", "tag:contract invoice"] {
            #expect(AdvancedSearchCompiler.usesSyntax(q), "\(q)")
        }
    }
}
