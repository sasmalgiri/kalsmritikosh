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
    /// Session circuit-breaker: once the resolved provider times out or fails,
    /// stop trying it and use the fast local fallback for the rest of the
    /// session (re-evaluated on next launch). Prevents a slow/degraded provider
    /// from making every batch of a large drain pay the full timeout.
    private var providerUnhealthy = false

    public init(capabilities: CapabilityRegistry, fallback: NLEmbedder = NLEmbedder()) {
        self.capabilities = capabilities
        self.fallback = fallback
        // The dimension is determined by whichever provider answers
        // first. The fallback's dimension is the safe default for
        // schema migration purposes.
        self.dimension = fallback.dimension
    }

    /// A slow/absent embedding provider (e.g. a reachable Ollama with no real
    /// embedding model) must NOT stall embedding. `isAvailable()` can pass while
    /// the actual embed call is pathologically slow, so each provider call is
    /// raced against a timeout; on timeout we fall back to the always-fast local
    /// `NLEmbedder` (warm ~1–5 ms). Generous enough that a healthy provider wins.
    private static let singleTimeout: TimeInterval = 6
    private static let batchTimeout: TimeInterval = 30

    public func embed(_ text: String) async -> [Float] {
        let spec = CapabilitySpec.embedding(purpose: "embed.text")
        if !providerUnhealthy,
           let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            let vector = await Self.race(timeout: Self.singleTimeout) {
                (try? await provider.embed(text: text)) ?? []
            }
            if let vector, !vector.isEmpty { return vector }
            markProviderUnhealthy(provider.id)
        }
        return await fallback.embed(text)
    }

    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let spec = CapabilitySpec.embedding(purpose: "embed.text.batch")
        if !providerUnhealthy,
           let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            let vectors = await Self.race(timeout: Self.batchTimeout) {
                (try? await provider.embedBatch(texts: texts)) ?? []
            }
            if let vectors, vectors.count == texts.count, !vectors.contains(where: \.isEmpty) {
                return vectors
            }
            markProviderUnhealthy(provider.id)
        }
        return await fallback.embedBatch(texts)
    }

    private func markProviderUnhealthy(_ providerID: String) {
        if !providerUnhealthy {
            providerUnhealthy = true
            KalsmritikoshLog.routing.info("Embedding provider \(providerID, privacy: .public) slow/failed — using local embedder for the rest of the session")
        }
    }

    /// Run `op`, returning its result, or `nil` if it doesn't finish within
    /// `timeout`. On timeout the op task is cancelled; provider embed calls are
    /// URLSession/HTTP-backed (Ollama, cloud) and honor cancellation, so the
    /// group unwinds promptly and the caller proceeds to the local fallback
    /// instead of stalling on a slow/degraded provider.
    private static func race<T: Sendable>(
        timeout: TimeInterval,
        _ op: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
