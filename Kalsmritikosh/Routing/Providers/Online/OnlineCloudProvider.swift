//
//  OnlineCloudProvider.swift
//  Kalsmritikosh
//
//  O-4 — the user's own cloud AI (Claude, OpenAI or Gemini) as a ModelProvider.
//  It resolves only when Online mode is genuinely in force (CapabilityRegistry
//  checks OnlineSettings.cloudAllowed) and only for text generation — never
//  embeddings. Every call, in order:
//
//    1. mask personal details when N-10 is on;
//    2. enforce the daily send limit (I-8; 0 = nothing may be sent);
//    3. show the exact text, destination and size and wait for consent (O-5);
//    4. send through the network helper (O-2) — this actor has no network;
//    5. log the send (O-5) with the SHA-256 of what left the Mac;
//    6. restore masked details in the reply.
//
//  Any failure is recorded for the user (O-7) and thrown; the answer pipeline's
//  evidence gate treats the output like any other generated text (O-6).
//

import Foundation
import CryptoKit
import os

public actor OnlineCloudProvider: @preconcurrency ModelProvider {
    public nonisolated let id = "provider.online.byok"
    public nonisolated let capabilities: Set<ModelCapability> = [
        .textGeneration, .structuredOutput, .longContext, .reasoning, .summarization, .extraction
    ]
    public nonisolated let manifest: ModelManifest

    private let outboundLog: OutboundLogRepository?
    private let knownNames: @Sendable () async -> [String]

    public init(outboundLog: OutboundLogRepository?, knownNames: @escaping @Sendable () async -> [String]) {
        self.outboundLog = outboundLog
        self.knownNames = knownNames
        self.manifest = ModelManifest(
            id: "provider.online.byok",
            displayName: "Your cloud AI (Online mode)",
            capabilities: [.textGeneration, .structuredOutput, .longContext, .reasoning, .summarization, .extraction],
            minRAMBytes: 0, diskBytes: 0, contextWindow: 200_000,
            privacyLevel: .cloud, requiresDownload: false, tier: .large)
    }

    public func isAvailable() async -> Bool {
        OnlineSettings.cloudAllowed && OnlineSettings.apiKey(for: OnlineSettings.kind) != nil
            && !OnlineSettings.model.isEmpty
    }

    public enum OnlineError: Error, LocalizedError {
        case notAvailable, declined, limitReached(Int)
        public var errorDescription: String? {
            switch self {
            case .notAvailable:       return "Online mode is not set up (choose a provider, model and key in Settings)."
            case .declined:           return "You chose not to send this to the cloud."
            case .limitReached(let c): return "Today's online limit (\(c) bytes) has been reached."
            }
        }
    }

    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        let kind = OnlineSettings.kind
        let model = OnlineSettings.model
        guard await isAvailable(), let key = OnlineSettings.apiKey(for: kind) else {
            throw await fail(OnlineError.notAvailable)
        }

        // 1. Masking (N-10).
        var sendPrompt = prompt
        var sendSystem = options.systemPrompt
        var mapping: [String: String] = [:]
        if ProductModuleFlags.isEnabled(.onlinePIIMasking) {
            let masker = OnlinePIIMasker(names: await knownNames())
            let p = masker.mask(prompt)
            sendPrompt = p.text
            mapping = p.mapping
            if let s = sendSystem {
                let m = masker.mask(s)
                sendSystem = m.text
                mapping.merge(m.mapping) { a, _ in a }
            }
        }
        let shownText = [sendSystem, sendPrompt].compactMap { $0 }.joined(separator: "\n\n")
        let bytes = shownText.utf8.count

        // 2. Daily limit (I-8).
        if ProductModuleFlags.isEnabled(.leastDataOnline), let cap = OnlineSettings.dailyByteCap {
            let used = (try? await outboundLog?.bytesSentToday()) ?? 0
            if used + bytes > cap {
                await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "daily limit")
                throw await fail(OnlineError.limitReached(cap))
            }
        }

        // 3. Consent (O-5) — not switchable.
        let preview = OutboundPreview(provider: kind.displayName, model: model, host: kind.host,
                                      text: shownText, bytes: bytes, maskedCount: mapping.count)
        guard await OutboundConsent.shared.request(preview) else {
            await log(kind, model, shownText, bytes, mapping.count, nil, "declined", nil)
            throw OnlineError.declined
        }

        // 4–6. Send, log, unmask.
        do {
            let request = try OnlineRequestBuilder.build(kind: kind, model: model, apiKey: key, system: sendSystem,
                                                         prompt: sendPrompt, maxTokens: options.maxTokens)
            let response = try await NetworkHelperClient.send(request)
            let text = try OnlineRequestBuilder.parse(kind: kind, response: response)
            await log(kind, model, shownText, bytes, mapping.count, response.body.count, "sent", nil)
            return OnlinePIIMasker.unmask(text, mapping: mapping)
        } catch {
            await log(kind, model, shownText, bytes, mapping.count, nil, "failed", error.localizedDescription)
            throw await fail(error)
        }
    }

    /// Embeddings never leave the Mac: this provider has no `.embedding` capability.
    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.unavailable(providerID: id)
    }

    private func fail(_ error: Error) async -> Error {
        let reason = error.localizedDescription
        KalsmritikoshLog.routing.error("Online answer failed: \(reason, privacy: .public)")
        await MainActor.run { OnlineStatus.shared.recordFailure(reason) }
        return error
    }

    private func log(_ kind: OnlineProviderKind, _ model: String, _ text: String, _ bytes: Int, _ masked: Int,
                     _ responseBytes: Int?, _ outcome: String, _ detail: String?) async {
        guard let outboundLog else { return }
        let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        do {
            try await outboundLog.record(OutboundLogEntry(
                id: UUID(), sentAt: Date(), provider: kind.rawValue, model: model, host: kind.host,
                bytesSent: outcome == "declined" || outcome == "blocked" ? 0 : bytes, maskedCount: masked,
                payloadSHA256: sha, payloadText: text, responseBytes: responseBytes, outcome: outcome, detail: detail))
        } catch {
            KalsmritikoshLog.routing.error("Outbound log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
