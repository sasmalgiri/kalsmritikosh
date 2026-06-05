//
//  CloudProvider.swift
//  Kalsmritikosh
//
//  Opt-in cloud routing slot, gated by PrivacyGate. Off by default.
//

import Foundation

public actor CloudProvider: ModelProvider {
    public let id = "provider.cloud"
    public let capabilities: Set<ModelCapability> = [
        .textGeneration, .structuredOutput, .longContext,
        .reasoning, .summarization, .extraction
    ]
    public let manifest: ModelManifest

    private let enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
        self.manifest = ModelManifest(
            id: "provider.cloud",
            displayName: "Cloud model (opt-in)",
            capabilities: [
                .textGeneration, .structuredOutput, .longContext,
                .reasoning, .summarization, .extraction
            ],
            minRAMBytes: 0,
            diskBytes: 0,
            contextWindow: 32_768,
            privacyLevel: .cloud,
            requiresDownload: false,
            tier: .large
        )
    }

    public func isAvailable() async -> Bool { enabled }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        throw ModelProviderError.unavailable(providerID: id)
    }

    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
    }
}
