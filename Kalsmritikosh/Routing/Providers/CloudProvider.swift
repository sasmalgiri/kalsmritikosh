//
//  CloudProvider.swift
//  Kalsmritikosh
//
//  OpenAI-compatible cloud endpoint. Resolves user-supplied API key
//  + base URL + model name via CloudEndpointRegistry. The brain's
//  CapabilityRegistry routes to this provider when the user has
//  registered a cloud endpoint AND PrivacyGate allows cloud routing.
//
//  Implements `/v1/chat/completions` against any endpoint that
//  speaks the OpenAI schema — OpenAI proper, Anthropic via their
//  OpenAI-compat layer, Azure OpenAI, OpenRouter, Together, hosted
//  Ollama with `OPENAI_API_BASE`, etc.
//
//  Privacy contract: this is the ONLY provider in the codebase
//  permitted to make network calls outside of Routing/Providers/.
//  PrivacyGate.shared.allowCloudRouting gates whether isAvailable()
//  returns true at all.
//

import Foundation
import OSLog

public actor CloudProvider: ModelProvider {
    public nonisolated let id: String
    public nonisolated let capabilities: Set<ModelCapability> = [
        .textGeneration, .structuredOutput, .longContext,
        .reasoning, .summarization, .extraction
    ]
    public nonisolated let manifest: ModelManifest

    private let baseURL: URL
    private let modelName: String
    private let apiKey: String
    private let enabled: Bool
    private let session: URLSession

    public init(enabled: Bool = false) {
        self.id = "provider.cloud"
        self.baseURL = URL(string: "https://api.openai.com/v1")!
        self.modelName = "gpt-4o-mini"
        self.apiKey = ""
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
        self.session = Self.makeSession()
    }

    /// G2-3 BYO — construct a CloudProvider from a user-registered
    /// `CloudEndpointRegistry.Endpoint`. The API key is read from
    /// Keychain at call time (not stored on this actor) so a key
    /// rotation in Settings takes effect immediately.
    public init(
        endpoint: CloudEndpointRegistry.Endpoint,
        apiKey: String
    ) {
        self.id = endpoint.id
        self.baseURL = URL(string: endpoint.baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.modelName = endpoint.modelName
        self.apiKey = apiKey
        self.enabled = true
        self.manifest = ModelManifest(
            id: endpoint.id,
            displayName: endpoint.displayName,
            capabilities: [
                .textGeneration, .structuredOutput, .longContext,
                .reasoning, .summarization, .extraction
            ],
            minRAMBytes: 0,
            diskBytes: 0,
            contextWindow: endpoint.contextWindow,
            privacyLevel: .cloud,
            requiresDownload: false,
            tier: endpoint.tier
        )
        self.session = Self.makeSession()
    }

    private nonisolated static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    public func isAvailable() async -> Bool {
        // Cloud routing is opt-in at the user level. PrivacyGate is the
        // single source of truth — adding an endpoint doesn't override
        // the user's privacy choice.
        guard PrivacyGate.shared.allowCloudRouting else { return false }
        guard enabled, !apiKey.isEmpty else { return false }
        return true
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        guard await isAvailable() else {
            throw ModelProviderError.unavailable(providerID: id)
        }
        // Counting happens at the scoped generate boundary (see ModelProvider).
        // OpenAI-compatible /chat/completions payload.
        var messages: [[String: Any]] = []
        if let system = options.systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": options.temperature,
            "top_p": options.topP,
            "max_tokens": options.maxTokens,
            "stream": false
        ]
        if !options.stopSequences.isEmpty {
            body["stop"] = options.stopSequences
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Anthropic via OpenAI-compat layer requires this header too;
        // harmless on OpenAI proper.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            KalsmritikoshLog.routing.error("CloudProvider \(self.id, privacy: .public) request failed: \(String(describing: error), privacy: .public)")
            throw ModelProviderError.generationFailed(reason: "\(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            KalsmritikoshLog.routing.error("CloudProvider \(self.id, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(bodyStr, privacy: .public)")
            throw ModelProviderError.generationFailed(
                reason: "HTTP \(http.statusCode): \(bodyStr.prefix(400))"
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw ModelProviderError.generationFailed(
                reason: "Unparseable response from \(id)"
            )
        }
        return content
    }

    public func embed(text: String) async throws -> [Float] {
        // OpenAI-compatible /v1/embeddings call. Uses the same
        // modelName as generate() unless the user has registered a
        // dedicated embedding endpoint (e.g. text-embedding-3-large).
        // Note: capabilities Set doesn't include .embedding by
        // default; only providers explicitly registered as
        // embedding-capable will be resolved for that spec. This
        // method exists so a future BYO endpoint type
        // "embedding-only" can use the same actor implementation.
        guard await isAvailable() else {
            throw ModelProviderError.unavailable(providerID: id)
        }
        let body: [String: Any] = [
            "model": modelName,
            "input": text
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelProviderError.generationFailed(reason: "\(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ModelProviderError.generationFailed(
                reason: "HTTP \(http.statusCode): \(bodyStr.prefix(400))"
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = root["data"] as? [[String: Any]],
              let first = dataArr.first,
              let embedding = first["embedding"] as? [Double]
        else {
            throw ModelProviderError.generationFailed(
                reason: "Unparseable embeddings response from \(id)"
            )
        }
        return embedding.map(Float.init)
    }
}
