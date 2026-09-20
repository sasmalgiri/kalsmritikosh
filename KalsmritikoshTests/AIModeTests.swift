//
//  AIModeTests.swift
//  KalsmritikoshTests
//
//  M1 — the AI-regime selector: default guided, persists, and its grounding
//  contract (guided enforces, unconstrained is advisory).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct AIModeTests {

    @Test("Default AI mode is guided (grounded contract)")
    func defaultIsGuided() {
        UserDefaults.standard.removeObject(forKey: FeatureFlags.aiModeKey)
        #expect(FeatureFlags.aiModeValue() == .guided)
        #expect(AIMode.guided.enforcesGrounding)
    }

    @Test("Unconstrained makes grounding advisory; the value persists and reads back")
    func unconstrainedAdvisoryAndPersists() {
        UserDefaults.standard.set(AIMode.unconstrained.rawValue, forKey: FeatureFlags.aiModeKey)
        #expect(FeatureFlags.aiModeValue() == .unconstrained)
        #expect(!AIMode.unconstrained.enforcesGrounding)
        // restore default
        UserDefaults.standard.set(AIMode.guided.rawValue, forKey: FeatureFlags.aiModeKey)
        #expect(FeatureFlags.aiModeValue() == .guided)
    }

    @Test("Every mode has a label + detail")
    func metadata() {
        for m in AIMode.allCases {
            #expect(!m.label.isEmpty)
            #expect(!m.detail.isEmpty)
        }
    }
}
