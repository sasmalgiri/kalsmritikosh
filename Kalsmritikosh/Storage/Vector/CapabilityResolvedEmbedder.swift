//
//  CapabilityResolvedEmbedder.swift
//  Kalsmritikosh
//
//  Asks the CapabilityRegistry for an embedding-capable model and
//  delegates to it. When no provider fulfils `.embedding` (or when the
//  call fails), falls back to `NLEmbedder`. Wrapped by `CachedEmbedder`
//  upstream so identical texts are not re-embedded.
//
//  The caller never names a model — only the capability.
//

import Foundation
import OSLog

public actor CapabilityResolvedEmbedder: Embedder {
    public let dimension: Int
    private let capabilities: CapabilityRegistry
    private let fallback: NLEmbedder

    public init(capabilities: CapabilityRegistry, fallback: NLEmbedder = NLEmbedder()) {
        self.capabilities = capabilities
        self.fallback = fallback
        // The dimension is determined by whichever provider answers
        // first. The fallback's dimension is the safe default for
        // schema migration purposes.
        self.dimension = fallback.dimension
    }

    public func embed(_ text: String) async -> [Float] {
        let spec = CapabilitySpec.embedding(purpose: "embed.text")
        if let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            do {
                let vector = try await provider.embed(text: text)
                if !vector.isEmpty { return vector }
            } catch {
                AtlasLog.routing.debug("Embedding via \(provider.id, privacy: .public) failed; falling back: \(String(describing: error), privacy: .public)")
            }
        }
        return await fallback.embed(text)
    }

    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let spec = CapabilitySpec.embedding(purpose: "embed.text.batch")
        if let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            do {
                let vectors = try await provider.embedBatch(texts: texts)
                if vectors.count == texts.count, !vectors.contains(where: \.isEmpty) {
                    return vectors
                }
            } catch {
                AtlasLog.routing.debug("Batch embedding via \(provider.id, privacy: .public) failed; falling back: \(String(describing: error), privacy: .public)")
            }
        }
        return await fallback.embedBatch(texts)
    }
}
