//
//  KnowledgeModuleFlagsTests.swift
//  KalsmritikoshTests
//
//  The module switchboard: implemented modules toggle and persist; a
//  not-yet-implemented module can never read as on.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct KnowledgeModuleFlagsTests {

    @Test("An implemented module toggles on and off and persists")
    func togglePersists() {
        let m = KnowledgeModule.topicMinimization
        #expect(m.implemented)
        KnowledgeModuleFlags.setEnabled(m, false)
        #expect(KnowledgeModuleFlags.isEnabled(m) == false)
        KnowledgeModuleFlags.setEnabled(m, true)
        #expect(KnowledgeModuleFlags.isEnabled(m) == true)
        // restore default
        KnowledgeModuleFlags.setEnabled(m, m.defaultEnabled)
    }

    @Test("Every registered module is implemented (all discussion items wired)")
    func allImplemented() {
        for m in KnowledgeModule.allCases {
            #expect(m.implemented, "module \(m.rawValue) should be implemented")
        }
    }

    @Test("Every module carries a title, detail, and group")
    func metadataComplete() {
        for m in KnowledgeModule.allCases {
            #expect(!m.title.isEmpty)
            #expect(!m.detail.isEmpty)
            #expect(!m.group.isEmpty)
        }
    }

    @Test("Implemented modules default on, except opt-in ledger-scoping ones")
    func implementedDefaultOn() {
        // Ledger-scoping modules intentionally default OFF (old behaviour stands
        // until the owner opts in); everything else implemented defaults ON.
        let optIn: Set<KnowledgeModule> = [.proseSubjectBinding, .aiSubjectResolution]
        for m in KnowledgeModule.allCases where m.implemented {
            if optIn.contains(m) { #expect(!m.defaultEnabled) }
            else { #expect(m.defaultEnabled) }
        }
    }
}
