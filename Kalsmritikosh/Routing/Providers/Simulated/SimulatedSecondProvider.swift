//
//  SimulatedSecondProvider.swift
//  Kalsmritikosh
//
//  Unified path R2-E (AI-16, owner 2026-11-22 round 2) — not tested yet. A SIMULATED second online provider (the plan's
//  "Sol/Astra"), built only as its own adapter behind the capability resolver: its own destination disclosure, its own
//  consent (a consent given to Claude never covers it, and its consent never covers Claude), typed failure semantics
//  (timeout, rate limit, refusal, malformed reply, unavailable), and a usage record per call. It opens NO connection:
//  replies come from a script. It is never registered by the app; the test phase registers it in its own registry
//  (KalsmritikoshTests/SimulatedAIProviderTests.swift). Every reply starts with "[SIMULATED]".
//

import Foundation
import os

public nonisolated struct SimulatedDestinationDisclosure: Sendable, Equatable {
    public let provider: String
    public let host: String
    public let region: String
    public let retention: String
    public let fields: [String]
    public let estimatedCostMicros: Int
    public var text: String {
        "SIMULATED send to \(provider) (\(host), \(region)). Fields: \(fields.joined(separator: ", ")). Estimated cost: $\(String(format: "%.4f", Double(estimatedCostMicros) / 1_000_000)). \(retention)"
    }
}

public actor SimulatedSecondProvider: ModelProvider {
    public enum Failure: Error, Equatable, LocalizedError {
        case timeout, rateLimited(retryAfterSeconds: Int), refused(String), malformed, unavailable, declined
        public var errorDescription: String? {
            switch self {
            case .timeout: return "SIMULATED second provider: no reply in time. Nothing was answered."
            case .rateLimited(let s): return "SIMULATED second provider: rate limited; try again in \(s) s."
            case .refused(let why): return "SIMULATED second provider refused: \(why)"
            case .malformed: return "SIMULATED second provider: the reply could not be read. Nothing was answered."
            case .unavailable: return "SIMULATED second provider is not set up."
            case .declined: return "You did not allow sending to the SIMULATED second provider."
            }
        }
    }
    public enum Step: Sendable { case reply(String), fail(Failure) }
    public struct Usage: Sendable, Equatable {
        public let at: Date
        public let promptCharacters: Int
        public let replyCharacters: Int
        public let costMicros: Int
        public let outcome: String
    }

    public nonisolated let id = "provider.simulated.second"
    public nonisolated let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning, .summarization, .extraction]
    public nonisolated let manifest = ModelManifest(id: "provider.simulated.second", displayName: "SIMULATED second online provider",
                                                    capabilities: [.textGeneration, .reasoning, .summarization, .extraction],
                                                    contextWindow: 100_000, privacyLevel: .cloud, tier: .large)
    public nonisolated static let host = "second-provider.simulated.invalid"

    private var script: [Step]
    private let enabled: Bool
    /// Consent for THIS destination only. Live code would show a dialog; the simulation scripts it.
    private let consent: @Sendable (SimulatedDestinationDisclosure) async -> Bool
    public private(set) var usage: [Usage] = []
    public private(set) var disclosures: [SimulatedDestinationDisclosure] = []

    public nonisolated init(script: [Step], enabled: Bool = true, consent: @escaping @Sendable (SimulatedDestinationDisclosure) async -> Bool) {
        self.script = script; self.enabled = enabled; self.consent = consent
    }

    public func isAvailable() async -> Bool { enabled }

    /// Simulated price: 3 micro-dollars per input character / 4, 15 per output token.
    nonisolated static func cost(promptChars: Int, replyChars: Int) -> Int { (promptChars / 4) * 3 + (replyChars / 4) * 15 }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        guard enabled else { record(prompt, "", "unavailable"); throw Failure.unavailable }
        let disclosure = SimulatedDestinationDisclosure(provider: manifest.displayName, host: Self.host, region: "simulated region",
                                                        retention: "Nothing leaves this Mac: SIMULATED.",
                                                        fields: ["question", "selected passages"],
                                                        estimatedCostMicros: Self.cost(promptChars: prompt.count, replyChars: options.maxTokens * 4))
        disclosures.append(disclosure)
        guard await consent(disclosure) else { record(prompt, "", "declined"); throw Failure.declined }
        guard !script.isEmpty else { record(prompt, "", "malformed"); throw Failure.malformed }
        switch script.removeFirst() {
        case .reply(let text):
            let out = "[SIMULATED] " + text
            record(prompt, out, "ok")
            return out
        case .fail(let f):
            record(prompt, "", "\(f)")
            KalsmritikoshLog.routing.notice("SIMULATED second provider failed: \(f.localizedDescription, privacy: .public)")
            throw f
        }
    }

    public func embed(text: String) async throws -> [Float] { throw Failure.refused("no embeddings") }

    private func record(_ prompt: String, _ reply: String, _ outcome: String) {
        usage.append(Usage(at: Date(), promptCharacters: prompt.count, replyCharacters: reply.count,
                           costMicros: outcome == "ok" ? Self.cost(promptChars: prompt.count, replyChars: reply.count) : 0, outcome: outcome))
    }
}
