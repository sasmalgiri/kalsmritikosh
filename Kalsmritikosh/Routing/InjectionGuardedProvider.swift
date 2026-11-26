//
//  InjectionGuardedProvider.swift
//  Kalsmritikosh
//
//  K9 — every resolved provider is handed out behind this wrapper, so every prompt that reaches any
//  model (answers, summaries, extraction, experts, planners, studio assists) has the instructions a
//  document may carry defanged, whichever code path assembled it. The person's own instructions live
//  in the system prompt, which is passed through untouched; embeddings get the raw text (defanging
//  would change what is indexed).
//

import Foundation

public struct InjectionGuardedProvider: ModelProvider {
    public let base: any ModelProvider
    private let injectionGuard = PromptInjectionGuard()

    public init(base: any ModelProvider) { self.base = base }

    public nonisolated var id: String { base.id }
    public nonisolated var capabilities: Set<ModelCapability> { base.capabilities }
    public nonisolated var manifest: ModelManifest { base.manifest }

    public func isAvailable() async -> Bool { await base.isAvailable() }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        try await base.generate(prompt: injectionGuard.defang(prompt), options: options)
    }

    public func generateStream(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        base.generateStream(prompt: injectionGuard.defang(prompt), options: options)
    }

    public func embed(text: String) async throws -> [Float] { try await base.embed(text: text) }

    public func embedBatch(texts: [String]) async throws -> [[Float]] { try await base.embedBatch(texts: texts) }
}
