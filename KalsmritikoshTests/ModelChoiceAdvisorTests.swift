//
//  ModelChoiceAdvisorTests.swift
//  KalsmritikoshTests
//
//  D-6 (completion instructions) — the advisor stays a PURE function; the new
//  trailing `foundationModelsHint` parameter changes nothing in dev builds
//  (whose no-provider branch recommends installing a local model) and feeds
//  the Release deterministic-mode details. The Release `#else` branch is
//  unreachable under a DEBUG test build, so the provider helper's fallback
//  string is exercised directly, per the completion instructions.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Model choice advisor (D-6)")
struct ModelChoiceAdvisorTests {

    private func hardware() -> HardwareProfile {
        HardwareProfile(
            totalRAMBytes: 16 * 1_073_741_824,
            availableRAMBytes: 8 * 1_073_741_824,
            processorCount: 8,
            isAppleSilicon: true,
            chipName: "TestChip",
            hasNeuralEngine: true
        )
    }

    @Test("unavailabilityHint is nil (model answering) or names the real remedy")
    func hintNamesTheRemedy() {
        // Environment-dependent by design: nil when Apple's model can answer
        // on this machine; otherwise every branch names Apple Intelligence /
        // the macOS 26 requirement — never Ollama, MLX, or cloud.
        if let hint = FoundationModelsProvider.unavailabilityHint() {
            #expect(hint.contains("Apple Intelligence") || hint.contains("macOS 26"))
            #expect(!hint.lowercased().contains("ollama"))
            #expect(!hint.lowercased().contains("cloud"))
        }
    }

    @Test("The hint parameter keeps the advisor pure — dev no-provider verdict unchanged")
    func hintDoesNotChangeDevBranch() {
        let without = ModelChoiceAdvisor.advise(
            hardware: hardware(), currentReasoning: nil, availableReasoning: [])
        let with = ModelChoiceAdvisor.advise(
            hardware: hardware(), currentReasoning: nil, availableReasoning: [],
            foundationModelsHint: "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to enable AI-written answers. Everything else already works.")
        // DEBUG test build → the dev branch (critical, install advice) for both;
        // identical output proves the parameter only feeds the Release branch.
        #expect(without == with)
        #expect(without.severity == .critical)
        #expect(without.recommendedProviderID == nil)
    }
}
