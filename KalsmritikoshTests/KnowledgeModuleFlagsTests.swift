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

    @Test("A not-yet-implemented module is never on, even if written")
    func unimplementedNeverOn() {
        let m = KnowledgeModule.boilerplateEmbedSkip
        #expect(!m.implemented)
        KnowledgeModuleFlags.setEnabled(m, true)         // attempt to force-enable
        #expect(KnowledgeModuleFlags.isEnabled(m) == false)
    }

    @Test("Every module carries a title, detail, and group")
    func metadataComplete() {
        for m in KnowledgeModule.allCases {
            #expect(!m.title.isEmpty)
            #expect(!m.detail.isEmpty)
            #expect(!m.group.isEmpty)
        }
    }

    @Test("Implemented modules default on")
    func implementedDefaultOn() {
        for m in KnowledgeModule.allCases where m.implemented {
            #expect(m.defaultEnabled)
        }
    }
}
