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
    public nonisolated let id = "provider.system.languageModel"
    public nonisolated let capabilities: Set<ModelCapability> = [
        .textGeneration, .structuredOutput, .toolCalling,
        .longContext, .reasoning, .summarization,
        .extraction, .classification
    ]
    public nonisolated let manifest: ModelManifest

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
            // Apple on-device SystemLanguageModel is a fixed 4,096-token window
            // (instructions + prompt + @Generable schema + output all count).
            // Not enlargeable — callers chunk to fit; see TokenBudget.
            contextWindow: 4096,
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

    /// Why Apple's on-device model can't answer right now, in the user's
    /// words — nil when it can (D-6, completion instructions). Surfaced in
    /// the Settings advisor banner and the deterministic-mode notice so the
    /// buyer learns the actual remedy (turn on Apple Intelligence / wait for
    /// the model / unsupported hardware) instead of a generic sentence.
    public static func unavailabilityHint() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to enable AI-written answers. Everything else already works."
                case .deviceNotEligible:
                    return "This Mac doesn't support Apple Intelligence, so AI-written answers aren't available here. Everything else works."
                case .modelNotReady:
                    return "Apple Intelligence is still preparing its on-device model. Try again in a few minutes."
                @unknown default:
                    return "Apple Intelligence isn't available on this Mac right now."
                }
            }
        }
        #endif
        return "AI-written prose requires macOS 26 or later with Apple Intelligence on supported hardware."
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            // Counting happens at the scoped generate boundary (see ModelProvider).
            let instructions = options.systemPrompt ?? "You are Kalsmritikosh, a precise knowledge-OS assistant."
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
                    let instructions = options.systemPrompt ?? "You are Kalsmritikosh, a precise knowledge-OS assistant."
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
