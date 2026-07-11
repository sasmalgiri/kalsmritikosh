//
//  OllamaProvider.swift
//  Kalsmritikosh
//
//  Real HTTP client for a local OSS model server (default
//  http://localhost:11434). Talks via the OpenAI-flavoured Ollama API.
//  Outside callers reach this provider only by declaring a
//  CapabilitySpec — they never name it.
//

import Foundation
import OSLog

// G2-SWIFT6 — known remaining warning on this conformance: the
// protocol's async methods (isAvailable / generate / embed / ...)
// come in nonisolated, while the actor's implementations are
// actor-isolated. The actor IS the synchronization boundary, so
// data races aren't actually possible — but Swift 6 strict
// concurrency can't prove that and `@preconcurrency` doesn't help
// on this specific shape. Deferred to a future commit that either
// migrates OllamaProvider to a value-type façade over a NIO/URLSession
// task, or splits the protocol into a nonisolated `Sendable`-prop
// half and an explicitly-isolated async half. Behavior is correct
// today.
public actor OllamaProvider: ModelProvider {
    // G2-SWIFT6 — explicit nonisolated to match the protocol's
    // nonisolated requirements (the registry reads these declaratively
    // before the actor is "live"). All three are immutable `let` set
    // once in init; nonisolated access is safe.
    public nonisolated let id: String
    public nonisolated let capabilities: Set<ModelCapability>
    public nonisolated let manifest: ModelManifest

    private let baseURL: URL
    private let modelTag: String
    private let embeddingModelTag: String?
    private let enabled: Bool
    private let session: URLSession

    public init(
        id: String = "provider.local.network",
        baseURL: URL = URL(string: "http://localhost:11434")!,
        modelTag: String = "qwen2.5:14b",
        embeddingModelTag: String? = "nomic-embed-text",
        enabled: Bool = false,
        displayName: String = "Local network model server",
        tier: ModelManifest.Tier = .medium,
        contextWindow: Int = 32_768,
        minRAMBytes: Int64 = 0
    ) {
        self.id = id
        self.baseURL = baseURL
        self.modelTag = modelTag
        self.embeddingModelTag = embeddingModelTag
        self.enabled = enabled

        // Same provider can host text generation + embedding when the
        // operator has pulled both kinds of models. We declare both
        // capabilities; the resolver picks based on the CapabilitySpec.
        var caps: Set<ModelCapability> = [
            .textGeneration, .reasoning, .summarization,
            .extraction, .classification, .longContext, .structuredOutput,
            // G2-1 — Ollama can serve the Reranker via prompted scoring
            // (no native cross-encoder endpoint; the Reranker actor's
            // prompt asks for a JSON array of [0,1] relevance scores).
            .reranking
        ]
        if embeddingModelTag != nil { caps.insert(.embedding) }
        self.capabilities = caps

        self.manifest = ModelManifest(
            id: id,
            displayName: displayName,
            capabilities: caps,
            minRAMBytes: minRAMBytes, // 0 when caller doesn't know; G2-3 discovery sets real bytes
            diskBytes: 0,
            contextWindow: contextWindow,
            privacyLevel: .localNetwork,
            requiresDownload: false,
            tier: tier
        )

        // Generous timeout — large models on first prompt can be slow.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["Content-Type": "application/json"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        guard enabled else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            KalsmritikoshLog.routing.debug("Ollama availability probe failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Generation

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        guard enabled else {
            throw ModelProviderError.unavailable(providerID: id)
        }
        guard !modelTag.isEmpty else {
            throw ModelProviderError.generationFailed(reason: "No model tag configured for Ollama provider.")
        }
        // Single source of truth for "an LLM generation ran" — every answer /
        // ingest / rerank call funnels through a provider boundary, so the Live
        // dashboard and RealDataProbe can count calls without threading a
        // counter through every caller.
        await LLMCallCounters.shared.recordCall(purpose: "generate")

        var body: [String: Any] = [
            "model": modelTag,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": options.temperature,
                "top_p": options.topP,
                "num_predict": options.maxTokens
            ]
        ]
        if !options.stopSequences.isEmpty {
            if var opts = body["options"] as? [String: Any] {
                opts["stop"] = options.stopSequences
                body["options"] = opts
            }
        }
        if let system = options.systemPrompt {
            body["system"] = system
        }

        let request = try makeRequest(path: "api/generate", body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ModelProviderError.generationFailed(
                    reason: "Ollama HTTP \(status): \(String(data: data, encoding: .utf8) ?? "(no body)")"
                )
            }
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let text = (decoded?["response"] as? String) ?? ""
            if text.isEmpty {
                throw ModelProviderError.generationFailed(reason: "Ollama returned empty response.")
            }
            return text
        } catch let error as ModelProviderError {
            throw error
        } catch {
            throw ModelProviderError.generationFailed(reason: "\(error)")
        }
    }

    // MARK: - Streaming generation

    public func generateStream(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        // Capture the actor's invariants up-front so the stream's
        // detached Task doesn't need actor re-entry to touch them.
        let enabled = self.enabled
        let providerID = self.id
        let modelTag = self.modelTag
        let baseURL = self.baseURL
        let session = self.session
        let opts = options

        return AsyncThrowingStream { continuation in
            guard enabled else {
                continuation.finish(throwing: ModelProviderError.unavailable(providerID: providerID))
                return
            }
            guard !modelTag.isEmpty else {
                continuation.finish(throwing: ModelProviderError.generationFailed(
                    reason: "No model tag configured for Ollama provider."
                ))
                return
            }

            Task {
                var body: [String: Any] = [
                    "model": modelTag,
                    "prompt": prompt,
                    "stream": true,
                    "options": [
                        "temperature": opts.temperature,
                        "top_p": opts.topP,
                        "num_predict": opts.maxTokens
                    ]
                ]
                if !opts.stopSequences.isEmpty, var inner = body["options"] as? [String: Any] {
                    inner["stop"] = opts.stopSequences
                    body["options"] = inner
                }
                if let system = opts.systemPrompt {
                    body["system"] = system
                }

                var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.finish(throwing: ModelProviderError.generationFailed(
                            reason: "Ollama HTTP \(http.statusCode)"
                        ))
                        return
                    }
                    // Ollama streams NDJSON: one JSON object per line, each
                    // with a "response" delta string and a "done" bool.
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let delta = dict["response"] as? String, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        if (dict["done"] as? Bool) == true {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Embedding

    public func embed(text: String) async throws -> [Float] {
        guard enabled else { throw ModelProviderError.unavailable(providerID: id) }
        guard let embedTag = embeddingModelTag, !embedTag.isEmpty else {
            throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
        }
        let body: [String: Any] = [
            "model": embedTag,
            "prompt": text
        ]
        let request = try makeRequest(path: "api/embeddings", body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ModelProviderError.generationFailed(
                    reason: "Ollama embeddings HTTP \(status): \(String(data: data, encoding: .utf8) ?? "(no body)")"
                )
            }
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Ollama returns "embedding": [Double]
            if let doubles = decoded?["embedding"] as? [Double] {
                return doubles.map { Float($0) }
            }
            if let numbers = decoded?["embedding"] as? [NSNumber] {
                return numbers.map { $0.floatValue }
            }
            throw ModelProviderError.generationFailed(reason: "Ollama embeddings: missing 'embedding' field.")
        } catch let error as ModelProviderError {
            throw error
        } catch {
            throw ModelProviderError.generationFailed(reason: "\(error)")
        }
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        guard enabled else { throw ModelProviderError.unavailable(providerID: id) }
        guard let embedTag = embeddingModelTag, !embedTag.isEmpty else {
            throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
        }
        guard !texts.isEmpty else { return [] }
        KalsmritikoshLog.ingestion.info("OllamaProvider.embedBatch: \(texts.count, privacy: .public) texts")
        // Newer Ollama exposes /api/embed accepting "input": [String].
        let body: [String: Any] = [
            "model": embedTag,
            "input": texts
        ]
        let request = try makeRequest(path: "api/embed", body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ModelProviderError.generationFailed(
                    reason: "Ollama embed batch HTTP \(status): \(String(data: data, encoding: .utf8) ?? "(no body)")"
                )
            }
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let arr = decoded?["embeddings"] as? [[Double]] {
                return arr.map { $0.map { Float($0) } }
            }
            if let arr = decoded?["embeddings"] as? [[NSNumber]] {
                return arr.map { $0.map { $0.floatValue } }
            }
            throw ModelProviderError.generationFailed(reason: "Ollama embed batch: missing 'embeddings' field.")
        } catch let error as ModelProviderError {
            throw error
        } catch {
            throw ModelProviderError.generationFailed(reason: "\(error)")
        }
    }

    // MARK: - Internals

    private func makeRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }
}
