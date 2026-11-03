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
