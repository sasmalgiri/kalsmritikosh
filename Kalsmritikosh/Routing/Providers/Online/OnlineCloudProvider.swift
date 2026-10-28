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
        case notAvailable, declined, limitReached(Int), notEligibleForDocuments(String), documentsNotCleared
        /// K8 — no reply within the deadline; nothing was answered.
        case timedOut
        /// K8 — the outbound record could not be written, so nothing was sent.
        case logUnavailable
        /// T1 — Online mode, the provider, its key or model, or the document terms changed while the
        /// consent dialog was open; the consent was given for a different send.
        case changedDuringConsent(String)
        public var errorDescription: String? {
            switch self {
            case .notEligibleForDocuments(let why): return why
            case .timedOut:           return "The provider did not reply in time. Nothing was answered; try again."
            case .logUnavailable:     return "Not sent: the record of what leaves this Mac could not be written."
            case .changedDuringConsent(let what): return "Not sent: \(what) changed while you were reviewing the request. Ask again to review it with the current settings."
            case .documentsNotCleared: return "Not sent: the passages were not checked for privilege and sensitivity before this request was built."
            case .notAvailable:       return "Online mode is not set up (choose a provider, model and key in Settings)."
            case .declined:           return "You chose not to send this to the cloud."
            case .limitReached(let c): return "Today's online limit (\(c) bytes) has been reached."
            }
        }
    }

    /// Review L2 — the general route (any capability resolved to this provider: composing an answer,
    /// summarising, extracting) may carry document passages, so it is treated as a document send:
    /// eligible, confirmed provider only, always previewed with the provider's terms.
    public func generate(prompt: String, options: GenerationOptions) async throws -> String {
        // K1: the general route may carry passages; it is sent only when its sources were cleared
        // (`CloudSourceGate`) before the prompt was assembled.
        guard options.sourceClearance != nil else {
            await log(OnlineSettings.kind, OnlineSettings.model, "", prompt.utf8.count, 0, nil, "blocked", "sources not cleared")
            throw await fail(OnlineError.documentsNotCleared)
        }
        return try await generateFromDocuments(prompt: prompt, options: options)
    }

    /// A request that carries only the question (and field names) — the question interpreter and
    /// rewriter. No document text may be passed here.
    public func generateQuestionOnly(prompt: String, options: GenerationOptions) async throws -> String {
        try await send(prompt: prompt, options: options, carriesDocuments: false)
    }

    /// Review L2 — a request that carries case-document excerpts. Sent only to a provider whose terms
    /// permit case material and whose terms the person confirmed for their account; always previewed
    /// with the provider's retention terms (never covered by "don't ask again this session").
    public func generateFromDocuments(prompt: String, options: GenerationOptions) async throws -> String {
        let kind = OnlineSettings.kind
        if let why = OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: OnlineSettings.confirmedDocumentTerms(for: kind)) {
            await log(kind, OnlineSettings.model, "", prompt.utf8.count, 0, nil, "blocked", "provider not eligible for documents")
            throw await fail(OnlineError.notEligibleForDocuments(why))
        }
        // K9 — document text reaches the model with any instruction it carries defanged.
        return try await send(prompt: PromptInjectionGuard().defang(prompt), options: options, carriesDocuments: true)
    }

    private func send(prompt: String, options: GenerationOptions, carriesDocuments: Bool) async throws -> String {
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
                                      text: shownText, bytes: bytes, maskedCount: mapping.count,
                                      carriesDocuments: carriesDocuments,
                                      providerTerms: carriesDocuments ? kind.documentTerms : nil)
        let beforeConsent = SendSettings.current(kind: kind, model: model, key: key)
        guard await OutboundConsent.shared.request(preview) else {
            await log(kind, model, shownText, bytes, mapping.count, nil, "declined", nil)
            throw OnlineError.declined
        }
        // T1 — the consent covers the send as previewed; if anything it depended on changed while the
        // dialog was open, nothing is sent.
        if let changed = SendSettings.changed(from: beforeConsent, to: SendSettings.current(kind: kind, model: model, key: nil),
                                              carriesDocuments: carriesDocuments) {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "changed during consent: \(changed)")
            throw await fail(OnlineError.changedDuringConsent(changed))
        }

        // K8 — what leaves the Mac is recorded BEFORE it leaves: no record, no send.
        do { try await recordPending(kind, model, shownText, mapping.count) }
        catch { throw await fail(OnlineError.logUnavailable) }

        // 4–6. Send (with a deadline), log, unmask.
        do {
            let request = try OnlineRequestBuilder.build(kind: kind, model: model, apiKey: key, system: sendSystem,
                                                         prompt: sendPrompt, maxTokens: options.maxTokens)
            let response = try await Self.withDeadline(Self.replyDeadline) { try await NetworkHelperClient.send(request) }
            let text = try OnlineRequestBuilder.parse(kind: kind, response: response)
            await log(kind, model, shownText, bytes, mapping.count, response.body.count, "sent", nil)
            return OnlinePIIMasker.unmask(text, mapping: mapping)
        } catch is CancellationError {
            // The person stopped it: recorded, not reported as a provider failure.
            await log(kind, model, shownText, bytes, mapping.count, nil, "cancelled", nil)
            throw CancellationError()
        } catch {
            await log(kind, model, shownText, bytes, mapping.count, nil, "failed", error.localizedDescription)
            throw await fail(error)
        }
    }

    /// K8 — the longest the person waits for a reply.
    static let replyDeadline: Duration = .seconds(120)

    /// Run `op`, failing with `.timedOut` after `deadline` and with `CancellationError` when the caller
    /// is cancelled — even if `op` itself never returns (an XPC reply that never comes).
    static func withDeadline<T: Sendable>(_ deadline: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = DeadlineResume<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                once.attach(c)
                Task { do { once.resume(.success(try await op())) } catch { once.resume(.failure(error)) } }
                Task { try? await Task.sleep(for: deadline); once.resume(.failure(OnlineError.timedOut)) }
            }
        } onCancel: { once.resume(.failure(CancellationError())) }
    }

    func recordPending(_ kind: OnlineProviderKind, _ model: String, _ text: String, _ masked: Int) async throws {
        guard let outboundLog else { throw OnlineError.logUnavailable }
        let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        try await outboundLog.record(OutboundLogEntry(
            id: UUID(), sentAt: Date(), provider: kind.rawValue, model: model, host: kind.host,
            bytesSent: 0, maskedCount: masked, payloadSHA256: sha, payloadText: text, responseBytes: nil,
            outcome: "sending", detail: nil))
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

/// Resumes a continuation exactly once, whichever of the reply, the deadline or the cancellation comes
/// first (a result that arrives before the continuation is attached is kept and delivered on attach).
final class DeadlineResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending { done = true; lock.unlock(); c.resume(with: pending); return }
        continuation = c
        lock.unlock()
    }

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        if let c = continuation { done = true; continuation = nil; lock.unlock(); c.resume(with: r); return }
        if pending == nil { pending = r }
        lock.unlock()
    }
}

/// T1 — what a consented send depends on, compared before and after the consent dialog.
nonisolated struct SendSettings: Equatable {
    let cloudAllowed: Bool
    let kind: OnlineProviderKind
    let model: String
    let keyDigest: String?
    let documentsEligible: Bool

    /// The settings now. `key` is the key read before the dialog (nil → read it again now).
    static func current(kind consentedKind: OnlineProviderKind, model consentedModel: String, key: String?) -> SendSettings {
        let kindNow = OnlineSettings.kind
        let keyNow = key ?? OnlineSettings.apiKey(for: kindNow)
        return SendSettings(cloudAllowed: OnlineSettings.cloudAllowed, kind: kindNow, model: OnlineSettings.model,
                            keyDigest: keyNow.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() },
                            documentsEligible: OnlineDocumentEligibility.refusal(kind: kindNow, confirmedTermsVersion: OnlineSettings.confirmedDocumentTerms(for: kindNow)) == nil)
    }

    /// What changed in a way that voids the consent, or nil.
    static func changed(from a: SendSettings, to b: SendSettings, carriesDocuments: Bool) -> String? {
        if !b.cloudAllowed { return "Online mode" }
        if a.kind != b.kind { return "the provider" }
        if a.keyDigest != b.keyDigest { return "the API key" }
        if a.model != b.model { return "the model" }
        if carriesDocuments && a.documentsEligible && !b.documentsEligible { return "the provider's document terms confirmation" }
        return nil
    }
}
