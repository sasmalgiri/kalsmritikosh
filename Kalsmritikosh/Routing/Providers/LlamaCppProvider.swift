//
//  LlamaCppProvider.swift
//  Kalsmritikosh
//
//  Bundled on-device reasoning provider (SHIP_DECISIONS: Llama-3.2-3B default,
//  Llama-3.1-8B optional). Internal-only file — outside callers reach it only
//  through the CapabilityRegistry via a CapabilitySpec, never by name.
//
//  This file owns the REAL runtime lifecycle (load/unload, streaming, context
//  enforcement, stop sequences, cancellation, memory-pressure unload, health)
//  around a `LlamaRuntime` seam. The actual llama.cpp C binding is a separate,
//  isolated implementation wired in P1.2 (it needs the llama.cpp SwiftPM/xcframework
//  dependency, which is a project-file change). Until that dependency is linked,
//  `UnavailableLlamaRuntime` is used: the build stays green and the provider
//  reports unavailable — NO fabricated output (quality-or-nothing). Nothing here
//  branches on a model name; the tag lives only in the manifest/registration.
//

import Foundation
import OSLog

// MARK: - Runtime seam

/// The thin inference surface the provider drives. The concrete llama.cpp-backed
/// implementation is added in P1.2 alongside the native dependency; it must
/// satisfy exactly this contract so the provider logic above it needs no changes.
public protocol LlamaRuntime: Sendable {
    /// Load the GGUF weights + build the context. Idempotent; throws on failure.
    func load() async throws
    /// Release native resources deterministically.
    func unload() async
    /// True once `load()` has succeeded and the context is live.
    func isLoaded() async -> Bool
    /// Stream generated tokens. Honors `options` (temperature/topP/maxTokens/stop/system)
    /// and the caller-supplied `contextWindow`. Terminates the stream on stop
    /// sequence, maxTokens, EOS, or `Task` cancellation.
    func stream(
        prompt: String,
        options: GenerationOptions,
        contextWindow: Int
    ) -> AsyncThrowingStream<String, Error>
}

/// Default runtime used until the native binding is linked (P1.2). Reports
/// not-loaded and refuses generation — the provider then reports unavailable,
/// so the registry simply skips it and the deterministic core is unaffected.
public struct UnavailableLlamaRuntime: LlamaRuntime {
    public init() {}
    public func load() async throws {
        throw ModelProviderError.generationFailed(
            reason: "llama.cpp runtime not linked yet (P1.2 dependency pending)."
        )
    }
    public func unload() async {}
    public func isLoaded() async -> Bool { false }
    public func stream(
        prompt: String,
        options: GenerationOptions,
        contextWindow: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: ModelProviderError.generationFailed(
                    reason: "llama.cpp runtime not linked yet (P1.2 dependency pending)."
                )
            )
        }
    }
}

// MARK: - Provider

public actor LlamaCppProvider: @preconcurrency ModelProvider {
    public nonisolated let id: String
    public nonisolated let capabilities: Set<ModelCapability>
    public nonisolated let manifest: ModelManifest

    /// The GGUF file on disk. `nil` = no model bundled/selected yet → unavailable.
    private let modelURL: URL?
    private let contextWindow: Int
    private let runtime: LlamaRuntime
    /// Sticky failure latch: once load fails we stop re-probing every call
    /// (avoids hammering a missing/corrupt file). Reset on `unload()`.
    private var loadFailed = false

    /// Default registration path (AppState). No bundled model wired yet, so the
    /// provider is inert (isAvailable == false) — identical to the prior stub.
    public init() {
        self.id = "provider.local.gguf"
        self.capabilities = [.textGeneration, .reasoning, .summarization, .extraction, .longContext, .structuredOutput]
        self.modelURL = nil
        self.contextWindow = 4096
        self.runtime = UnavailableLlamaRuntime()
        self.manifest = ModelManifest(
            id: "provider.local.gguf",
            displayName: "Local GGUF runtime",
            capabilities: [.textGeneration, .reasoning, .summarization, .extraction, .longContext, .structuredOutput],
            minRAMBytes: 8 * 1_073_741_824,
            diskBytes: 0,
            contextWindow: 4096,
            privacyLevel: .onDevice,
            requiresDownload: true,
            tier: .medium
        )
    }

    /// Bundled/selected-model path (P3.1). `runtime` defaults to the native
    /// binding once P1.2 links it; callers may inject a stub in tests.
    public init(
        id: String,
        modelURL: URL,
        manifest: ModelManifest,
        contextWindow: Int,
        runtime: LlamaRuntime
    ) {
        self.id = id
        self.capabilities = manifest.capabilities
        self.manifest = manifest
        self.modelURL = modelURL
        self.contextWindow = contextWindow
        self.runtime = runtime
    }

    // MARK: Availability

    public func isAvailable() async -> Bool {
        guard modelURL != nil, !loadFailed else { return false }
        if await runtime.isLoaded() { return true }
        do {
            try await runtime.load()
            return true
        } catch {
            loadFailed = true
            KalsmritikoshLog.routing.error("LlamaCppProvider \(self.id, privacy: .public) load failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Generation

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        // Single-shot = drain the token stream. The scoped budget boundary in
        // ModelProvider.generate(...purpose:context:) has already reserved the
        // call; this raw path only produces text.
        var out = ""
        for try await token in generateStream(prompt: prompt, options: options) {
            out += token
        }
        if out.isEmpty {
            throw ModelProviderError.generationFailed(reason: "Empty response from local model \(id).")
        }
        return out
    }

    public nonisolated func generateStream(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        // Hop onto the actor to read state + drive the runtime; enforce stop
        // sequences here too (defensive — the runtime honors them, but the
        // provider is the contract boundary). Cancellation propagates through
        // the inner stream's iterator.
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = try await self.openStream(prompt: prompt, options: options)
                    // Accumulate only to detect a stop sequence the runtime may
                    // have split across token boundaries; the runtime is the
                    // primary stop authority, this is a defensive backstop.
                    var seen = ""
                    let stops = options.stopSequences.filter { !$0.isEmpty }
                    for try await token in inner {
                        try Task.checkCancellation()
                        if let stop = stops.first(where: { (seen + token).contains($0) }) {
                            // Emit up to (not including) the stop, then finish.
                            let combined = seen + token
                            if let r = combined.range(of: stop) {
                                let keep = String(combined[..<r.lowerBound])
                                if keep.count > seen.count {
                                    continuation.yield(String(keep.dropFirst(seen.count)))
                                }
                            }
                            continuation.finish()
                            return
                        }
                        seen += token
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Actor-isolated: ensure loaded, then hand back the runtime's token stream.
    private func openStream(
        prompt: String,
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard modelURL != nil else {
            throw ModelProviderError.unavailable(providerID: id)
        }
        if !(await runtime.isLoaded()) {
            do {
                try await runtime.load()
            } catch {
                loadFailed = true
                throw ModelProviderError.unavailable(providerID: id)
            }
        }
        return runtime.stream(prompt: prompt, options: options, contextWindow: contextWindow)
    }

    // MARK: Embedding — not this provider's job

    public func embed(text: String) async throws -> [Float] {
        // Reasoning provider only. Embeddings come from the dedicated bundled
        // embedding provider (BGE-small), never the reasoning model.
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
    }

    // MARK: Resource management

    /// Release the model under memory pressure. A subsequent request reloads it
    /// lazily. Clears the failure latch so a transient OOM doesn't permanently
    /// disable the provider.
    public func releaseUnderMemoryPressure() async {
        await runtime.unload()
        loadFailed = false
        KalsmritikoshLog.routing.info("LlamaCppProvider \(self.id, privacy: .public) unloaded (memory pressure).")
    }
}
