//
//  AIModeTests.swift
//  KalsmritikoshTests
//
//  M1 — the AI-regime selector: default guided, persists, and its grounding
//  contract (guided enforces, unconstrained is advisory).
//
//  TWO HAZARDS THESE TESTS HAD, both found by the first full-suite run:
//
//  1. A RACE. `defaultIsGuided` removes the AI-mode key and asserts the default,
//     while `unconstrainedAdvisoryAndPersists` writes a non-default value to the
//     SAME key. Swift Testing runs tests in parallel, so the writer could land
//     between the remover's write and its read — and did: the full run reported
//     `aiModeValue() → .unconstrained` where `.guided` was expected, a failure
//     that never reproduced when the suite was run alone. `.serialized` removes
//     the interleaving.
//
//  2. A LIVE SETTING MUTATED BY A TEST RUN. `UserDefaults.standard` in the test
//     host is the APP's defaults domain, so these tests were writing the real
//     AI-mode preference — a test run could leave the owner's app in
//     unconstrained, or (on the failing path) with the key deleted. Each test
//     now captures the prior value and restores it, whatever the outcome.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite(.serialized) struct AIModeTests {

    /// Run `body` with the AI-mode default isolated: whatever was there before
    /// is put back afterwards, including when an expectation fails.
    private func withIsolatedAIMode(_ body: () -> Void) {
        let key = FeatureFlags.aiModeKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test("Default AI mode is guided (grounded contract)")
    func defaultIsGuided() {
        withIsolatedAIMode {
            UserDefaults.standard.removeObject(forKey: FeatureFlags.aiModeKey)
            #expect(FeatureFlags.aiModeValue() == .guided)
            #expect(AIMode.guided.enforcesGrounding)
        }
    }

    @Test("Unconstrained makes grounding advisory; the value persists and reads back")
    func unconstrainedAdvisoryAndPersists() {
        withIsolatedAIMode {
            UserDefaults.standard.set(AIMode.unconstrained.rawValue, forKey: FeatureFlags.aiModeKey)
            #expect(FeatureFlags.aiModeValue() == .unconstrained)
            #expect(!AIMode.unconstrained.enforcesGrounding)
            UserDefaults.standard.set(AIMode.guided.rawValue, forKey: FeatureFlags.aiModeKey)
            #expect(FeatureFlags.aiModeValue() == .guided)
        }
    }

    @Test("Every mode has a label + detail")
    func metadata() {
        for m in AIMode.allCases {
            #expect(!m.label.isEmpty)
            #expect(!m.detail.isEmpty)
        }
    }

    @Test("An unrecognized stored value falls back to guided, never to unconstrained")
    func unknownStoredValueFallsBackToGuided() {
        // The fallback direction is a safety property, not a detail: a corrupt
        // or future-version preference must leave grounding ENFORCED rather
        // than silently loosening the answer contract.
        withIsolatedAIMode {
            UserDefaults.standard.set("not-a-mode", forKey: FeatureFlags.aiModeKey)
            #expect(FeatureFlags.aiModeValue() == .guided)
        }
    }
}
