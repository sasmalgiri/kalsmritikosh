//
//  AIRegimeMatrixTests.swift
//  KalsmritikoshTests
//
//  The unified AI posture (Fully private / gated / free) and the module
//  dependency matrix: AI-only modules die under Fully-private; a module whose
//  prerequisite is off is effectively disabled; deterministic modules are never
//  gated by the AI regime. The user's stored choice is preserved across regimes.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite(.serialized) struct AIRegimeMatrixTests {

    /// Keys this suite mutates; snapshot + restore so it never leaks into others.
    private static let touchedKeys = [
        "kalsmritikosh.privacy.offlineNoLLM",
        FeatureFlags.aiModeKey,
        KnowledgeModuleFlags.storageKey(.autoTopics),
        KnowledgeModuleFlags.storageKey(.aiSubjectResolution),
    ]
    private func snapshot() -> [String: Any?] {
        Dictionary(uniqueKeysWithValues: Self.touchedKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    }
    private func restore(_ s: [String: Any?]) {
        for (k, v) in s { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
    }

    @Test("Regime round-trips through the two underlying flags")
    func regimeRoundTrip() {
        let s = snapshot(); defer { restore(s) }
        FeatureFlags.setAIRegime(.fullyPrivate)
        #expect(FeatureFlags.aiRegimeValue() == .fullyPrivate)
        #expect(PrivacyGate.shared.offlineNoLLM == true)

        FeatureFlags.setAIRegime(.gated)
        #expect(FeatureFlags.aiRegimeValue() == .gated)
        #expect(PrivacyGate.shared.offlineNoLLM == false)
        #expect(FeatureFlags.aiModeValue() == .guided)

        FeatureFlags.setAIRegime(.free)
        #expect(FeatureFlags.aiRegimeValue() == .free)
        #expect(PrivacyGate.shared.offlineNoLLM == false)
        #expect(FeatureFlags.aiModeValue() == .unconstrained)
    }

    @Test("Fully-private force-disables AI modules but never deterministic ones; the stored choice survives")
    func fullyPrivateGatesOnlyAI() {
        let s = snapshot(); defer { restore(s) }
        // The user opted an AI module ON while AI is allowed.
        FeatureFlags.setAIRegime(.gated)
        KnowledgeModuleFlags.setEnabled(.aiSubjectResolution, true)
        #expect(KnowledgeModuleFlags.isEnabled(.aiSubjectResolution) == true)
        #expect(KnowledgeModuleFlags.disabledReason(.aiSubjectResolution) == nil)

        // Switch to Fully private → the AI module is effectively off with an AI reason…
        FeatureFlags.setAIRegime(.fullyPrivate)
        #expect(KnowledgeModuleFlags.isEnabled(.aiSubjectResolution) == false)
        #expect(KnowledgeModuleFlags.disabledReason(.aiSubjectResolution)?.contains("Needs AI") == true)
        // …but a deterministic module (actor answers) is untouched by the regime.
        #expect(KnowledgeModuleFlags.disabledReason(.actorComposer) == nil)
        #expect(KnowledgeModuleFlags.isEnabled(.actorComposer) == true)

        // Back to gated → the user's ON choice is remembered, not erased.
        FeatureFlags.setAIRegime(.gated)
        #expect(KnowledgeModuleFlags.isEnabled(.aiSubjectResolution) == true)
    }

    @Test("A module whose prerequisite is off is effectively disabled with a Requires reason")
    func dependencyGate() {
        let s = snapshot(); defer { restore(s) }
        FeatureFlags.setAIRegime(.gated)               // AI allowed, so only the dep matters
        KnowledgeModuleFlags.setEnabled(.autoTopics, true)
        #expect(KnowledgeModuleFlags.disabledReason(.topicMinimization) == nil)

        KnowledgeModuleFlags.setEnabled(.autoTopics, false)
        #expect(KnowledgeModuleFlags.isEnabled(.topicMinimization) == false)
        #expect(KnowledgeModuleFlags.disabledReason(.topicMinimization)?.contains("Requires") == true)

        KnowledgeModuleFlags.setEnabled(.autoTopics, true)
        #expect(KnowledgeModuleFlags.disabledReason(.topicMinimization) == nil)
    }

    @Test("requiresAI + dependsOn classification is correct")
    func classification() {
        #expect(KnowledgeModule.aiSubjectResolution.requiresAI)
        #expect(KnowledgeModule.topicProsePolish.requiresAI)
        #expect(KnowledgeModule.aiComposeEveryAnswer.requiresAI)
        #expect(KnowledgeModule.hydeExpansion.requiresAI)
        #expect(!KnowledgeModule.actorComposer.requiresAI)          // deterministic
        #expect(!KnowledgeModule.crossEncoderRerank.requiresAI)     // CoreML, not the LLM
        #expect(!KnowledgeModule.autoTopics.requiresAI)
        #expect(KnowledgeModule.topicMinimization.dependsOn.contains(.autoTopics))
        #expect(KnowledgeModule.autoTopics.dependsOn.isEmpty)
    }
}
