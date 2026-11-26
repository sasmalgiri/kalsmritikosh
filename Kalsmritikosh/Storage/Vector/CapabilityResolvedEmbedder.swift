//
//  CapabilityResolvedEmbedder.swift
//  Kalsmritikosh
//
//  Asks the CapabilityRegistry for an embedding-capable model and
//  delegates to it. A failed or slow call is retried with back-off; only a
//  genuinely unavailable provider falls back to `NLEmbedder`, with every
//  vector labelled by the embedder that made it and the degraded state
//  recorded (Fix PERF-28, owner 2026-11-23). Wrapped by `CachedEmbedder`
//  upstream so identical texts are not re-embedded.
//
//  The caller never names a model — only the capability.
//

import Foundation
import OSLog

public actor CapabilityResolvedEmbedder: Embedder {
    /// CACHE-IDENTITY DEFAULT — NOT the serving model's dimension. This is
    /// the fallback's dimension, fixed at init because it keys cache/model
    /// identity ("embedder-<dimension>") before any provider has resolved.
    /// For the dimension of whoever actually answered, see
    /// `servingDimension`/`servingProviderID` (set after first resolve).
    /// The rc0 baseline artifact mislabeled its drain because of this name.
    public let dimension: Int
    /// Diagnostics for receipts/harnesses (ratified, unit B): identity of
    /// the provider that actually served, populated after the first
    /// successful embed. nil until then; fallback use records the fallback.
    public private(set) var servingProviderID: String?
    public private(set) var servingDimension: Int?
    private let capabilities: CapabilityRegistry
    private let fallback: NLEmbedder
    /// Fix PERF-28 (owner 2026-11-23): the embedder whose vectors the active store holds (its label + size), nil when the
    /// caller did not say (tests). A fallback vector is never labelled with it.
    private let primary: EmbeddingProducer?
    /// The fallback's own label (the local word embedder).
    public nonisolated static let fallbackProducerID = EmbedderIdentity.localFallbackStoreID
    private var fallbackProducer: EmbeddingProducer { EmbeddingProducer(id: Self.fallbackProducerID, dimension: fallback.dimension) }

    /// Fix PERF-28 (owner 2026-11-23). Was: a session circuit-breaker — one slow call under load and every later vector
    /// came from the 300-d fallback, still stored under the primary's 384-d label (the IVF-0 cause). Now: a slow or failed
    /// call is RETRIED with a longer wait and backs off (AdaptiveConcurrency halves the calls in flight); only when the
    /// primary is genuinely unavailable (not resolvable / reports unavailable, or `unavailableAfter` failed calls in a
    /// row, every one after its retries) is the fallback used — labelled as the fallback, with the degraded state recorded
    /// (EmbeddingHealth) and the primary re-probed every `reprobeSeconds`.
    private var consecutiveFailedCalls = 0
    private var failingSince: Date?
    private var degradedSince: Date?
    private var degradedReason: String?
    private var lastProbe: Date?
    public private(set) var state: EmbeddingHealth.State = .healthy
    private let limiter: AdaptiveConcurrency
    private let attemptTimeouts: [TimeInterval]
    private let singleTimeouts: [TimeInterval]
    private let unavailableAfter: Int
    private let reprobeSeconds: TimeInterval
    private let backoffBase: Duration

    public init(capabilities: CapabilityRegistry, fallback: NLEmbedder = NLEmbedder(), primary: EmbeddingProducer? = nil,
                batchTimeouts: [TimeInterval] = [30, 90, 240], singleTimeouts: [TimeInterval] = [6, 20],
                unavailableAfter: Int = 10, reprobeSeconds: TimeInterval = 300, backoffBase: Duration = .milliseconds(500)) {
        self.capabilities = capabilities
        self.fallback = fallback
        // The dimension is determined by whichever provider answers
        // first. The fallback's dimension is the safe default for
        // schema migration purposes.
        self.dimension = fallback.dimension
        self.primary = primary
        self.attemptTimeouts = batchTimeouts.isEmpty ? [30] : batchTimeouts
        self.singleTimeouts = singleTimeouts.isEmpty ? [6] : singleTimeouts
        self.unavailableAfter = max(1, unavailableAfter)
        self.reprobeSeconds = reprobeSeconds
        self.backoffBase = backoffBase
        self.limiter = AdaptiveConcurrency(start: 2, cap: 4)
    }

    /// The producer a vector made now would carry.
    public var expectedProducer: EmbeddingProducer? {
        get async {
            if degradedSince != nil, !reprobeDue() { return fallbackProducer }
            if let primary { return primary }
            if let id = servingProviderID, let d = servingDimension { return EmbeddingProducer(id: id, dimension: d) }
            return nil
        }
    }

    public func embed(_ text: String) async -> [Float] {
        let r = await embedLabelled([text], timeouts: singleTimeouts, purpose: "embed.text")
        return r.vectors.first ?? []
    }

    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        await embedBatchLabelled(texts).vectors
    }

    public func embedBatchLabelled(_ texts: [String]) async -> LabelledEmbeddings {
        guard !texts.isEmpty else { return .unlabelled([]) }
        return await embedLabelled(texts, timeouts: attemptTimeouts, purpose: "embed.text.batch")
    }

    private func reprobeDue() -> Bool {
        guard let lastProbe else { return true }
        return Date().timeIntervalSince(lastProbe) >= reprobeSeconds
    }

    private func embedLabelled(_ texts: [String], timeouts: [TimeInterval], purpose: String) async -> LabelledEmbeddings {
        // Degraded: the fallback until the next re-probe of the primary.
        if degradedSince != nil, !reprobeDue() { return await fallbackLabelled(texts) }
        let spec = CapabilitySpec.embedding(purpose: purpose)
        lastProbe = Date()
        guard let provider = try? await capabilities.resolve(spec) else {
            return await degrade(texts, reason: "no on-device embedder could be resolved")
        }
        guard await provider.isAvailable() else {
            return await degrade(texts, reason: "the on-device embedder reports it is unavailable")
        }
        let label = EmbedderIdentity.storeModelID(forProviderID: provider.id)
        for (attempt, timeout) in timeouts.enumerated() {
            if Task.isCancelled { break }
            await limiter.acquire()
            let vectors = await Self.race(timeout: timeout) {
                (try? await provider.embedBatch(texts: texts)) ?? []
            }
            if let vectors, vectors.count == texts.count, !vectors.contains(where: \.isEmpty),
               let d = vectors.first?.count, vectors.allSatisfy({ $0.count == d }) {
                await limiter.release(.success)
                recordServing(id: label, dimension: d)
                recovered(provider.id)
                return LabelledEmbeddings(vectors: vectors, producers: vectors.map { _ in EmbeddingProducer(id: label, dimension: d) })
            }
            // A timeout or a failed / short / ragged answer: back off and try again with a longer wait.
            await limiter.release(.overloaded(retryAfter: nil))
            KalsmritikoshLog.routing.info("Embedding provider \(provider.id, privacy: .public) attempt \(attempt + 1, privacy: .public)/\(timeouts.count, privacy: .public) failed (\(vectors == nil ? "timed out" : "no usable vectors", privacy: .public)) — retrying, nothing labelled with another embedder")
            if attempt + 1 < timeouts.count {
                do { try await Task.sleep(for: backoffBase * (1 << attempt)) } catch {
                    KalsmritikoshLog.routing.debug("Embedding retry back-off cancelled")
                    break
                }
            }
        }
        consecutiveFailedCalls += 1
        if failingSince == nil { failingSince = Date() }
        if consecutiveFailedCalls >= unavailableAfter {
            return await degrade(texts, reason: "the on-device embedder failed \(consecutiveFailedCalls) calls in a row, each after \(timeouts.count) attempts")
        }
        state = .retrying(primary: primary?.id ?? label, since: failingSince ?? Date(), failures: consecutiveFailedCalls)
        EmbeddingHealth.set(state)
        return LabelledEmbeddings(vectors: texts.map { _ in [] }, producers: texts.map { _ in nil }, transientFailure: true)
    }

    /// The fallback's vectors, labelled as the fallback's.
    private func fallbackLabelled(_ texts: [String]) async -> LabelledEmbeddings {
        let vs = await fallback.embedBatch(texts)
        recordServing(id: Self.fallbackProducerID, dimension: fallback.dimension)
        let p = fallbackProducer
        return LabelledEmbeddings(vectors: vs, producers: vs.map { $0.isEmpty ? nil : p })
    }

    /// The primary is genuinely unavailable. When the primary IS the fallback (no bundled embedder: the store holds
    /// fallback vectors), that is the normal state, not a degradation.
    private func degrade(_ texts: [String], reason: String) async -> LabelledEmbeddings {
        if let primary, primary.id != Self.fallbackProducerID {
            if degradedSince == nil {
                degradedSince = Date()
                KalsmritikoshLog.routing.error("Embeddings DEGRADED: \(reason, privacy: .public). Vectors now come from the fallback and are stored under \(Self.fallbackProducerID, privacy: .public), never \(primary.id, privacy: .public); the primary is re-probed every \(Int(self.reprobeSeconds), privacy: .public) s")
            }
            degradedReason = reason
            state = .degraded(primary: primary.id, fallback: Self.fallbackProducerID, since: degradedSince ?? Date(), reason: reason)
            EmbeddingHealth.set(state)
        }
        return await fallbackLabelled(texts)
    }

    private func recovered(_ providerID: String) {
        if degradedSince != nil || failingSince != nil {
            KalsmritikoshLog.routing.info("Embedding provider \(providerID, privacy: .public) answering again — embeddings healthy")
        }
        consecutiveFailedCalls = 0
        failingSince = nil
        degradedSince = nil
        degradedReason = nil
        if state != .healthy { state = .healthy; EmbeddingHealth.set(.healthy) }
    }

    private func recordServing(id: String, dimension: Int) {
        servingProviderID = id
        servingDimension = dimension
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
