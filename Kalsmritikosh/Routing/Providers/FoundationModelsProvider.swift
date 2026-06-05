//
//  FoundationModelsProvider.swift
//  Kalsmritikosh
//
//  Internal-only file. Outside callers reach this provider only by
//  declaring a CapabilitySpec — they never name it.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FoundationModelsProvider: ModelProvider {
    public let id = "provider.system.languageModel"
    public let capabilities: Set<ModelCapability> = [
        .textGeneration, .structuredOutput, .toolCalling,
        .longContext, .reasoning, .summarization,
        .extraction, .classification
    ]
    public let manifest: ModelManifest

    public init() {
        self.manifest = ModelManifest(
            id: "provider.system.languageModel",
            displayName: "System language model",
            capabilities: [
                .textGeneration, .structuredOutput, .toolCalling,
                .longContext, .reasoning, .summarization,
                .extraction, .classification
            ],
            minRAMBytes: 0,
            diskBytes: 0,
            contextWindow: 8192,
            privacyLevel: .onDevice,
            requiresDownload: false,
            tier: .medium
        )
    }

    public func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
        return false
        #else
        return false
        #endif
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let instructions = options.systemPrompt ?? "You are Atlas, a precise knowledge-OS assistant."
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: Prompt(prompt))
            return response.content
        }
        throw ModelProviderError.unavailable(providerID: id)
        #else
        throw ModelProviderError.unavailable(providerID: id)
        #endif
    }

    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.capabilityMissing(providerID: id, capability: .embedding)
    }

    public func generateStream(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        return AsyncThrowingStream { continuation in
            Task {
                if #available(macOS 26.0, iOS 26.0, *) {
                    let instructions = options.systemPrompt ?? "You are Atlas, a precise knowledge-OS assistant."
                    let session = LanguageModelSession(instructions: instructions)
                    do {
                        let stream = session.streamResponse(to: Prompt(prompt))
                        // The stream produces growing snapshots of the
                        // full response; we forward each delta downstream.
                        var lastEmitted = ""
                        for try await snapshot in stream {
                            let text = snapshot.content
                            if text.count > lastEmitted.count {
                                let delta = String(text.dropFirst(lastEmitted.count))
                                continuation.yield(delta)
                                lastEmitted = text
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } else {
                    continuation.finish(throwing: ModelProviderError.unavailable(providerID: id))
                }
            }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ModelProviderError.unavailable(providerID: id))
        }
        #endif
    }
}
