//
//  LlamaCppProvider.swift
//  Atlas chronica memora
//

import Foundation

public struct LlamaCppProvider: ModelProvider {
    public let id = "provider.local.gguf"
    public let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
    public let manifest: ModelManifest

    public init() {
        self.manifest = ModelManifest(
            id: "provider.local.gguf",
            displayName: "Local GGUF runtime",
            capabilities: [.textGeneration, .reasoning],
            minRAMBytes: 8 * 1_073_741_824,
            diskBytes: 0,
            contextWindow: 4096,
            privacyLevel: .onDevice,
            requiresDownload: true,
            tier: .medium
        )
    }

    public func isAvailable() async -> Bool { false }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        throw ModelProviderError.unavailable(providerID: id)
    }

    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
    }
}
