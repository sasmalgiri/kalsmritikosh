//
//  ModelProvider.swift
//  Kalsmritikosh
//
//  Every AI call goes through the CapabilityRegistry, which resolves a
//  CapabilitySpec to a concrete ModelProvider. Callers (experts, the
//  router, the brain) never name a specific provider or model — they
//  declare what they need.
//

import Foundation

public protocol ModelProvider: Sendable {
    /// Opaque identifier used only inside the registry. Callers must NOT
    /// reference this string anywhere; it's purely for registry bookkeeping.
    // G2-SWIFT6 — nonisolated so log statements can reference these
    // from any actor / nonisolated context without "main-actor-isolated
    // property cannot be referenced from a nonisolated autoclosure".
    nonisolated var id: String { get }

    /// Capabilities this provider exposes — used by CapabilityRegistry to
    /// match providers to CapabilitySpecs.
    nonisolated var capabilities: Set<ModelCapability> { get }

    /// Describes what this provider can do, where it runs, and how heavy
    /// it is. Surfaced to the CapabilityRegistry for cost-aware ranking.
    nonisolated var manifest: ModelManifest { get }

    /// Whether this provider is currently usable (model loaded, OS feature
    /// enabled, network reachable for cloud, etc.).
    func isAvailable() async -> Bool

    /// Free-form text generation.
    func generate(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String

    /// Streaming text generation. Providers that don't support real
    /// streaming should rely on the default extension below, which wraps
    /// `generate(prompt:options:)` and yields the whole result as one
    /// terminal chunk. Apple's `SystemLanguageModel` and Ollama's
    /// `stream:true` API both override this with real token-by-token
    /// streams.
    func generateStream(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>

    /// Embedding vector for a piece of text. Only valid when capabilities
    /// contains `.embedding` — otherwise throws.
    func embed(text: String) async throws -> [Float]

    /// Batch embedding. Providers that expose a native batch endpoint
    /// (Ollama /api/embed, Apple's batched encoder) override; the default
    /// loops over `embed(text:)`.
    func embedBatch(texts: [String]) async throws -> [[Float]]
}

extension ModelProvider {
    /// Budget-enforced generation boundary (§6). Reserves one call from the
    /// request's shared `LLMCallBudget` BEFORE inference — throwing
    /// `LLMCallBudgetError.exhausted` when the ceiling is hit — then delegates
    /// to the provider's raw `generate(prompt:options:)` and records the call's
    /// terminal status. A failed or cancelled call still consumes the
    /// reservation (compute/network was attempted; never auto-refunded, §4).
    /// When `context` is nil (background / not-yet-migrated work) no budget is
    /// enforced and it behaves exactly like the raw call.
    public func generate(
        prompt: String,
        options: GenerationOptions,
        purpose: String,
        context: LLMRequestContext?
    ) async throws -> String {
        // This scoped boundary is now the SINGLE counting + budgeting point for
        // query-time generation. Order matters: reserve() FIRST so a
        // budget-rejected call never counts (no compute happened); then record
        // (attributed to the request, so RealDataProbe can count by requestID
        // and background calls stay separate); then run.
        guard let context else {
            await LLMCallCounters.shared.recordCall(purpose: purpose, requestID: nil, providerID: id)
            return try await generate(prompt: prompt, options: options)
        }
        let reservation = try await context.budget.reserve(purpose: purpose, providerID: id)
        await LLMCallCounters.shared.recordCall(
            purpose: purpose, requestID: context.rootRequestID, providerID: id
        )
        do {
            let result = try await generate(prompt: prompt, options: options)
            await context.budget.finish(sequence: reservation, status: .completed)
            return result
        } catch is CancellationError {
            await context.budget.finish(sequence: reservation, status: .cancelled)
            throw CancellationError()
        } catch {
            await context.budget.finish(sequence: reservation, status: .failed)
            throw error
        }
    }

    /// Default batch impl: loop over `embed(text:)`. Providers should
    /// override when a real batch endpoint is available.
    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts { try await out.append(self.embed(text: t)) }
        return out
    }

    /// Default streaming impl: fall back to single-shot `generate`.
    public func generateStream(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.generate(prompt: prompt, options: options)
                    continuation.yield(response)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// What a model is good at — both low-level (textGeneration, embedding) and
/// semantic-task tiers (reasoning, summarization, extraction). Experts ask
/// for tiers; the registry maps tiers to whichever provider best fulfils
/// them on this hardware.
public enum ModelCapability: String, Codable, Sendable, Hashable, CaseIterable {
    // Low-level primitives
    case textGeneration
    case structuredOutput
    case toolCalling
    case embedding
    case vision
    case longContext

    // Semantic task tiers (M6.1 addition)
    case reasoning
    case summarization
    case extraction
    case classification
    case routing
    case complexityAnalysis

    /// G2-1 — pairwise relevance scoring of (claim, candidate evidence).
    /// EvidenceVerifier uses this to reorder citation survivors by
    /// claim-relevance instead of pure retrieval similarity, which is
    /// what closes the lookup-precision gap at Gate 1 (0.33 → ≥ 0.6).
    /// Providers that can produce a single normalized score for an
    /// (anchor, candidate) pair declare this.
    case reranking

    // Size hints used by cost-aware ranking
    case routerSmall
    case expertLarge
}

public struct GenerationOptions: Sendable, Hashable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var stopSequences: [String]
    public var systemPrompt: String?

    public nonisolated init(
        maxTokens: Int = 1024,
        temperature: Double = 0.4,
        topP: Double = 0.95,
        stopSequences: [String] = [],
        systemPrompt: String? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.systemPrompt = systemPrompt
    }
}

public enum ModelProviderError: Error, Sendable {
    case unavailable(providerID: String)
    case capabilityMissing(providerID: String, capability: ModelCapability)
    case generationFailed(reason: String)
    case noProviderForSpec(spec: CapabilitySpec)
}

// MARK: - PrivacyLevel

/// Where a model runs. Used by CapabilityRegistry + PrivacyGate to decide
/// whether a provider is eligible for the current privacy mode.
public enum PrivacyLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case onDevice
    case localNetwork  // e.g. an Ollama server on the same LAN
    case cloud
}

// MARK: - LatencyHint

/// Lets callers say "I'm OK waiting" vs "this must be interactive". The
/// registry uses this to rank providers when several fulfil the spec.
// G2-SWIFT6 — Comparable conformance moved to a nonisolated extension
// at the bottom of this file so CapabilityRegistry's actor-isolated
// comparisons don't pick up main-actor isolation from synthesis.
public enum LatencyHint: String, Codable, Sendable, Hashable {
    case interactive   // < 500ms tokens-to-first
    case background    // okay if it takes seconds
    case bulk          // batch jobs, no UI waiting

    nonisolated fileprivate var order: Int {
        switch self {
        case .interactive: return 0
        case .background: return 1
        case .bulk: return 2
        }
    }
    public nonisolated static func < (lhs: LatencyHint, rhs: LatencyHint) -> Bool {
        lhs.order < rhs.order
    }
}

// G2-SWIFT6 — explicit nonisolated Comparable conformance.
nonisolated extension LatencyHint: Comparable {}
