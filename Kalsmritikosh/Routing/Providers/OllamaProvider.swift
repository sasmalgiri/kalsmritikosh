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

public actor OllamaProvider: ModelProvider {
    public let id = "provider.local.network"
    public let capabilities: Set<ModelCapability>
    public let manifest: ModelManifest

    private let baseURL: URL
    private let modelTag: String
    private let embeddingModelTag: String?
    private let enabled: Bool
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        modelTag: String = "qwen2.5:14b",
        embeddingModelTag: String? = "nomic-embed-text",
        enabled: Bool = false,
        displayName: String = "Local network model server",
        tier: ModelManifest.Tier = .medium,
        contextWindow: Int = 32_768
    ) {
        self.baseURL = baseURL
        self.modelTag = modelTag
        self.embeddingModelTag = embeddingModelTag
        self.enabled = enabled

        // Same provider can host text generation + embedding when the
        // operator has pulled both kinds of models. We declare both
        // capabilities; the resolver picks based on the CapabilitySpec.
        var caps: Set<ModelCapability> = [
            .textGeneration, .reasoning, .summarization,
            .extraction, .classification, .longContext, .structuredOutput
        ]
        if embeddingModelTag != nil { caps.insert(.embedding) }
        self.capabilities = caps

        self.manifest = ModelManifest(
            id: "provider.local.network",
            displayName: displayName,
            capabilities: caps,
            minRAMBytes: 0,        // server handles its own memory budget
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
            AtlasLog.routing.debug("Ollama availability probe failed: \(String(describing: error), privacy: .public)")
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
            body["options", default: [:]]
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
        AtlasLog.ingestion.info("OllamaProvider.embedBatch: \(texts.count, privacy: .public) texts")
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
