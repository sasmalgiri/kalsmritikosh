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

    @Test("Implemented modules default on, except the explicitly opt-in ones")
    func implementedDefaultOn() {
        // Everything implemented defaults ON — it IS the current behaviour —
        // except these, and each exception needs a stated reason. The set is
        // closed on purpose: a new module quietly defaulting OFF is a feature
        // nobody has, and this test is what forces that choice to be argued.
        let optIn: Set<KnowledgeModule> = [
            // Ledger-SCOPING changes: the old behaviour stands until the owner
            // opts in, because these alter what a fact attaches to.
            .proseSubjectBinding, .aiSubjectResolution,
            // P3.3 — a different reason, and the only module of its kind: it is
            // the one writer whose output a model had a hand in, so it is not
            // reproducible. P3.1/P3.2/P3.4 are deterministic and default ON; a
            // NON-deterministic writer into the ledger should be a deliberate
            // choice rather than something a user discovers in their data.
            .inducedSchema,
        ]
        for m in KnowledgeModule.allCases where m.implemented {
            if optIn.contains(m) {
                #expect(!m.defaultEnabled, "\(m.rawValue) is listed opt-in but defaults ON")
            } else {
                #expect(m.defaultEnabled, "\(m.rawValue) defaults OFF without being listed as opt-in — state why, then add it here")
            }
        }
    }
}
