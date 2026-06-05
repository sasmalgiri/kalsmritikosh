//
//  MLXProvider.swift
//  Atlas chronica memora
//
//  Internal-only file. Outside callers register this with the
//  CapabilityRegistry and from then on refer to it only via capabilities.
//
//  M6.1 ships a registry-shaped provider that reports unavailable until
//  mlx-swift is wired in M6.2. The Manifest declares the role and
//  hardware footprint without naming a specific model.
//

import Foundation

public actor MLXProvider: ModelProvider {
    public let id: String
    public let capabilities: Set<ModelCapability>
    public let manifest: ModelManifest

    private let downloader: ModelDownloader

    public init(
        id: String,
        manifest: ModelManifest,
        downloader: ModelDownloader
    ) {
        self.id = id
        self.manifest = manifest
        self.capabilities = manifest.capabilities
        self.downloader = downloader
    }

    public func isAvailable() async -> Bool {
        false
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        throw ModelProviderError.unavailable(providerID: id)
    }

    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
    }
}
