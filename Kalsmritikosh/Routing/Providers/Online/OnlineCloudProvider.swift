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
    /// Release-block directive item 1 — the protected source identities recorded in the ledger's
    /// source vaults (jrn.source-vault). Always masked, whatever the PII-masking setting; a request in
    /// which one would still be recoverable after masking is not sent.
    private let protectedNames: @Sendable () async throws -> [String]
    private let seams: Seams

    /// What the send reads from outside the actor: the Online settings, the person's consent and the
    /// transport. Live: OnlineSettings, the consent dialog and the network helper. Tests pass their
    /// own (a settings snapshot, a scripted consent, a transport spy) so the real send path runs
    /// without touching the owner's settings or the network.
    public struct Seams: Sendable {
        public var settings: @Sendable () -> OnlineSnapshot
        public var consent: @Sendable (OutboundPreview) async -> Bool
        public var transport: @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse
        public init(settings: @escaping @Sendable () -> OnlineSnapshot,
                    consent: @escaping @Sendable (OutboundPreview) async -> Bool,
                    transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse) {
            self.settings = settings; self.consent = consent; self.transport = transport
        }
        /// Plan A — whether the person allowed this case's document set (fingerprint) to be read by
        /// their AI (asked once per case, CaseReadPermissionStore). Tests script it.
        public var casePermission: @Sendable (_ caseID: UUID, _ fingerprint: String) -> Bool = { caseID, fingerprint in
            CaseReadPermissionStore.live.isGranted(caseID: caseID, fingerprint: fingerprint)
        }
        public static let live = Seams(settings: { OnlineSnapshot.current() },
                                       consent: { await OutboundConsent.shared.request($0) },
                                       transport: { try await NetworkHelperClient.send($0) })
    }

    public init(outboundLog: OutboundLogRepository?, knownNames: @escaping @Sendable () async -> [String],
                protectedNames: @escaping @Sendable () async throws -> [String] = { [] }, seams: Seams = .live) {
        self.outboundLog = outboundLog
        self.knownNames = knownNames
        self.protectedNames = protectedNames
        self.seams = seams
        self.manifest = ModelManifest(
            id: "provider.online.byok",
            displayName: "Your cloud AI (Online mode)",
            capabilities: [.textGeneration, .structuredOutput, .longContext, .reasoning, .summarization, .extraction],
            minRAMBytes: 0, diskBytes: 0, contextWindow: 200_000,
            privacyLevel: .cloud, requiresDownload: false, tier: .large)
    }

    public func isAvailable() async -> Bool {
        let s = seams.settings()
        return s.cloudAllowed && s.apiKey != nil && !s.model.isEmpty
    }

    public enum OnlineError: Error, LocalizedError {
        case notAvailable, declined, limitReached(Int), notEligibleForDocuments(String), documentsNotCleared
        /// A protected source identity (jrn.source-vault) would still be recoverable after masking.
        case protectedIdentity(Int)
        /// N7 — the protected-identity register could not be read or failed its integrity check: not
        /// knowing which names to protect is never "no names to protect".
        case protectionUnreadable
        /// K8 — no reply within the deadline; nothing was answered.
        case timedOut
        /// K8 — the outbound record could not be written, so nothing was sent.
        case logUnavailable
        /// T1 — Online mode, the provider, its key or model, or the document terms changed while the
        /// consent dialog was open; the consent was given for a different send.
        case changedDuringConsent(String)
        /// Plan A — a whole-case read without the person's stored permission for exactly these documents.
        case caseNotPermitted
        public var errorDescription: String? {
            switch self {
            case .caseNotPermitted:   return "Not sent: you have not allowed the AI to read this case's current documents."
            case .notEligibleForDocuments(let why): return why
            case .timedOut:           return "The provider did not reply in time. Nothing was answered; try again."
            case .logUnavailable:     return "Not sent: the record of what leaves this Mac could not be written."
            case .changedDuringConsent(let what): return "Not sent: \(what) changed while you were reviewing the request. Ask again to review it with the current settings."
            case .documentsNotCleared: return "Not sent: the passages were not checked for privilege and sensitivity before this request was built."
            case .protectedIdentity(let n): return "Not sent: \(n) protected source identity(ies) would still be recoverable in the request after masking."
            case .protectionUnreadable: return "Not sent: the register of protected source identities could not be read, so the request could not be checked for them. Restore the case's source vault or run it again."
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
            let s = seams.settings()
            await log(s.kind, s.model, "", prompt.utf8.count, 0, nil, "blocked", "sources not cleared")
            throw await fail(OnlineError.documentsNotCleared)
        }
        return try await generateFromDocuments(prompt: prompt, options: options)
    }

    /// P1 — whether a document-bearing request could be sent now (Online set up, provider eligible for
    /// case documents, its terms confirmed). Readers check this first, so an ineligible setup is not
    /// recorded as a failed send on every question; `generateFromDocuments` still enforces it.
    public func acceptsDocuments() async -> Bool {
        let s = seams.settings()
        guard await isAvailable() else { return false }
        return OnlineDocumentEligibility.refusal(kind: s.kind, confirmedTermsVersion: s.confirmedDocumentTerms) == nil
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
        let s = seams.settings()
        let kind = s.kind
        if let why = OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: s.confirmedDocumentTerms) {
            await log(kind, s.model, "", prompt.utf8.count, 0, nil, "blocked", "provider not eligible for documents")
            throw await fail(OnlineError.notEligibleForDocuments(why))
        }
        // K9 — document text reaches the model with any instruction it carries defanged.
        return try await send(prompt: PromptInjectionGuard().defang(prompt), options: options, carriesDocuments: true)
    }

    /// A4 — read scanned pages the Mac's own text recognition could not: the page images go to the
    /// person's chosen provider (or AI Included) as a document send — eligible, confirmed provider only,
    /// always previewed (the preview lists every image and says images cannot be masked).
    /// The person chose this file explicitly; it has no ledger record yet, so there is no source
    /// clearance to check — the choice and the consent are the authority.
    public func readPageImages(_ images: [OutboundImage], fileName: String) async throws -> String {
        let s = seams.settings()
        if let why = OnlineDocumentEligibility.refusal(kind: s.kind, confirmedTermsVersion: s.confirmedDocumentTerms) {
            await log(s.kind, s.model, "", 0, 0, nil, "blocked", "provider not eligible for documents")
            throw await fail(OnlineError.notEligibleForDocuments(why))
        }
        guard !images.isEmpty else { return "" }
        let prompt = """
        These are scanned pages of “\(fileName)” that on-device text recognition could not read. Transcribe every page verbatim, in reading order. Start each page with a line “=== \(images.count == 1 ? images[0].label : "page N") ===” using the page labels given in order: \(images.map(\.label).joined(separator: ", ")). Keep the original language, spelling, numbers and line breaks of tables. Mark anything you cannot read as [illegible] and handwriting you are unsure of as [uncertain: …]. Do not summarise, correct, translate, explain or add anything.
        """
        return try await send(prompt: prompt, options: GenerationOptions(maxTokens: 8_000), carriesDocuments: true, images: images)
    }

    /// A11 — transcribe a recording with speaker labels and timecodes (AI Included, or Gemini with the
    /// person's own key). A document send: eligible, confirmed provider only; always previewed.
    public func transcribeRecording(_ audio: OutboundImage, fileName: String) async throws -> String {
        let s = seams.settings()
        if let why = OnlineDocumentEligibility.refusal(kind: s.kind, confirmedTermsVersion: s.confirmedDocumentTerms) {
            await log(s.kind, s.model, "", 0, 0, nil, "blocked", "provider not eligible for documents")
            throw await fail(OnlineError.notEligibleForDocuments(why))
        }
        guard s.kind == .included || s.kind == .gemini else {
            throw await fail(OnlineRequestBuilder.BuildError.audioNotSupported(s.kind.displayName))
        }
        let prompt = "Transcribe the recording “\(fileName)” verbatim. Label each turn with a speaker label (Speaker 1, Speaker 2, …) and a start time [mm:ss]. Do not summarise, translate, correct or add anything; mark inaudible parts as [inaudible]."
        return try await send(prompt: prompt, options: GenerationOptions(maxTokens: 8_192), carriesDocuments: true, images: [audio])
    }

    private func send(prompt: String, options: GenerationOptions, carriesDocuments: Bool,
                      images: [OutboundImage] = []) async throws -> String {
        let settings = seams.settings()
        let kind = settings.kind
        let model = settings.model
        guard await isAvailable(), let key = settings.apiKey else {
            throw await fail(OnlineError.notAvailable)
        }

        // 1. Masking (N-10) — and, whatever the setting, the protected source identities of the
        //    ledger's source vaults (release-block directive item 1).
        var sendPrompt = prompt
        var sendSystem = options.systemPrompt
        var mapping: [String: String] = [:]
        let protected: [String]
        do { protected = try await protectedNames() } catch {
            await log(kind, model, "", 0, 0, nil, "blocked", "protected-identity register unreadable")
            throw await fail(OnlineError.protectionUnreadable)
        }
        var maskNames = protected
        if ProductModuleFlags.isEnabled(.onlinePIIMasking) { maskNames += await knownNames() }
        if !maskNames.isEmpty {
            let masker = OnlinePIIMasker(names: maskNames)
            let p = masker.mask(prompt)
            sendPrompt = p.text
            mapping = p.mapping
            if let s = sendSystem {
                let m = masker.mask(s)
                sendSystem = m.text
                mapping.merge(m.mapping) { a, _ in a }
            }
        }
        // A4 — each image is listed (label, size, SHA-256) in what is previewed and recorded; the images
        // themselves cannot be masked, which the preview says.
        let imageManifest = images.map { img in
            "[\(img.mediaType.hasPrefix("image/") ? "image" : "recording") \(img.label): \(img.mediaType), \(img.data.count) bytes, SHA-256 \(SHA256.hash(data: img.data).map { String(format: "%02x", $0) }.joined())]"
        }
        let shownText = ([sendSystem, sendPrompt].compactMap { $0 } + imageManifest).joined(separator: "\n\n")
        let bytes = shownText.utf8.count + images.reduce(0) { $0 + $1.data.count }
        // A protected identity that survives masking (split by markup, spacing or case) stops the send.
        let survivors = RedactionVerifier().leaks(in: shownText, protectedTerms: protected, artifact: "request")
        if !survivors.isEmpty {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "protected source identity")
            throw await fail(OnlineError.protectedIdentity(survivors.count))
        }

        // 2. Daily limit (I-8).
        if ProductModuleFlags.isEnabled(.leastDataOnline), let cap = settings.dailyByteCap {
            let used = (try? await outboundLog?.bytesSentToday()) ?? 0
            if used + bytes > cap {
                await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "daily limit")
                throw await fail(OnlineError.limitReached(cap))
            }
        }
        // Plans and credits (2026-11-04) — the person's own monthly limit for their own Anthropic key.
        if kind == .anthropic, let why = OwnKeyBudget.refusal() {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "own-key monthly limit")
            throw await fail(OwnKeyBudget.LimitReached(reason: why))
        }

        // 3. Consent (O-5) — not switchable. Plan A: a send inside a case whose every passage comes from
        //    the documents the person allowed for that case (CaseReadPermittedSet, checked against the
        //    stored permission here) is covered by that permission — no second preview. Anything else —
        //    a document outside the permitted set, images, no case — is previewed as always.
        let coveredByCase = images.isEmpty && Self.coveredByCasePermission(
            CaseReadPermittedSet.current, clearance: options.sourceClearance, carriesDocuments: carriesDocuments,
            granted: seams.casePermission)
        let beforeConsent = SendSettings(settings)
        if coveredByCase {
            KalsmritikoshLog.routing.info("online send covered by the case's stored permission — no per-send preview")
        } else {
            // B2 (agent legal review): AI Included sends a recording to Google Gemini, not to Claude — the
            // preview names the provider and model that will actually receive it.
            let isRecording = images.contains { $0.mediaType.hasPrefix("audio/") || $0.mediaType.hasPrefix("video/") }
            let shownProvider = kind == .included && isRecording ? "AI Included → Google Gemini (transcription)" : kind.displayName
            let shownModel = kind == .included && isRecording ? "Gemini (chosen by the AI Included service)" : model
            var preview = OutboundPreview(provider: shownProvider, model: shownModel, host: kind.host,
                                          text: shownText, bytes: bytes, maskedCount: mapping.count,
                                          carriesDocuments: carriesDocuments,
                                          providerTerms: carriesDocuments ? (images.isEmpty ? kind.documentTerms
                                              : kind.documentTerms + " The \(images.count) attachment(s) (page images or a recording) are sent as they are: names or details shown or spoken in them cannot be masked.") : nil,
                                          aiIncluded: kind == .included)
            // Plans and credits — what this send may cost: credits on an AI plan, dollars on an own Anthropic key.
            preview.costEstimate = await Self.costEstimate(kind: kind, model: model, system: sendSystem, prompt: sendPrompt,
                                                           images: images, maxTokens: options.maxTokens)
            guard await seams.consent(preview) else {
                await log(kind, model, shownText, bytes, mapping.count, nil, "declined", nil)
                throw OnlineError.declined
            }
        }
        // T1 — the consent covers the send as previewed; if anything it depended on changed while the
        // dialog was open, nothing is sent.
        if let changed = SendSettings.changed(from: beforeConsent, to: SendSettings(seams.settings()),
                                              carriesDocuments: carriesDocuments) {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "changed during consent: \(changed)")
            throw await fail(OnlineError.changedDuringConsent(changed))
        }
        // A6 — the documents themselves are re-cleared at the send boundary: one made privileged,
        // restricted, moved out of reach or erased while the dialog was open stops the send.
        if let clearance = options.sourceClearance, let why = await clearance.stillCleared() {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "sources changed during consent")
            throw await fail(OnlineError.changedDuringConsent(why))
        }

        // N7 — the protection register is read again at the send boundary: a name protected while the
        // dialog was open, or a register that became unreadable, stops the send.
        do {
            let now = try await protectedNames()
            let late = RedactionVerifier().leaks(in: shownText, protectedTerms: now, artifact: "request")
            if !late.isEmpty {
                await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "protected identity added during consent")
                throw await fail(OnlineError.protectedIdentity(late.count))
            }
        } catch let e as OnlineError { throw e } catch {
            await log(kind, model, shownText, bytes, mapping.count, nil, "blocked", "protected-identity register unreadable")
            throw await fail(OnlineError.protectionUnreadable)
        }

        // A7 — a cancel during the dialog or the checks: nothing is sent.
        if Task.isCancelled {
            await log(kind, model, shownText, bytes, mapping.count, nil, "cancelled", "before sending")
            throw CancellationError()
        }
        // K8 — what leaves the Mac is recorded BEFORE it leaves: no record, no send.
        do { try await recordPending(kind, model, shownText, mapping.count) }
        catch { throw await fail(OnlineError.logUnavailable) }

        // 4–6. Send (with a deadline), log, unmask.
        var dispatched = false
        do {
            let request = try OnlineRequestBuilder.build(kind: kind, model: model, apiKey: key, system: sendSystem,
                                                         prompt: sendPrompt, maxTokens: options.maxTokens, images: images)
            try Task.checkCancellation()
            dispatched = true
            let response = try await Self.withDeadline(Self.replyDeadline) { [seams] in try await seams.transport(request) }
            // A11 — AI Included's transcription route answers in Gemini's form (its refusals in the relay's).
            let isAudio = images.contains { $0.mediaType.hasPrefix("audio/") || $0.mediaType.hasPrefix("video/") }
            if kind == .included, response.status >= 400, let why = AIIncludedRelay.refusal(in: response.body) {
                throw OnlineRequestBuilder.ParseError.relay(why)
            }
            let text = try OnlineRequestBuilder.parse(kind: kind == .included && isAudio ? .gemini : kind, response: response)
            if kind == .included { AICreditMeter.recordReceipt(responseBody: response.body) }
            else if kind == .anthropic { OwnKeyBudget.record(responseBody: response.body, model: model) }
            await log(kind, model, shownText, bytes, mapping.count, response.body.count, "sent",
                      coveredByCase ? "covered by the case's stored permission" : nil)
            return OnlinePIIMasker.unmask(text, mapping: mapping)
        } catch is CancellationError {
            // The person stopped it: recorded, not reported as a provider failure. Once dispatched, the
            // request may already have reached the provider — said so, never "not sent".
            await log(kind, model, shownText, bytes, mapping.count, nil, "cancelled",
                      dispatched ? "stopped waiting; delivery unknown" : "before sending")
            throw CancellationError()
        } catch {
            await log(kind, model, shownText, bytes, mapping.count, nil, "failed", error.localizedDescription)
            throw await fail(error)
        }
    }

    /// Plan A — whether a send is covered by the case's stored permission: a permitted set is carried,
    /// the person's stored permission matches its fingerprint (recomputed, never the caller's), and a
    /// document send's clearance holds only permitted documents at permitted versions, bound to that
    /// case. A question-only send inside the case (the question interpreter) carries no document text
    /// and is covered by the same permission the question itself is sent under on the whole-case path.
    static func coveredByCasePermission(_ permitted: CaseReadPermittedSet?, clearance: CloudSourceClearance?, carriesDocuments: Bool,
                                        granted: @Sendable (UUID, String) -> Bool) -> Bool {
        guard let permitted, !permitted.versions.isEmpty, granted(permitted.caseID, permitted.fingerprint) else { return false }
        guard carriesDocuments else { return true }
        guard let clearance else { return false }
        return permitted.covers(clearance)
    }

    /// Plans and credits (2026-11-04) — the estimate the consent dialog shows (nil when none applies).
    static func costEstimate(kind: OnlineProviderKind, model: String, system: String?, prompt: String,
                             images: [OutboundImage], maxTokens: Int) async -> String? {
        let pictures = images.filter { $0.mediaType.hasPrefix("image/") }.count
        let chars = (system?.count ?? 0) + prompt.count
        let tokens = AIPricing.approximateTokens(characters: chars) + pictures * 1_600
        let maxOut = OnlineRequestBuilder.anthropicMaxTokens(maxTokens)
        switch kind {
        case .anthropic:
            return OwnKeyBudget.estimateLine(model: model, inputTokens: tokens, maxOutputTokens: maxOut)
        case .included:
            if images.contains(where: { !$0.mediaType.hasPrefix("image/") }) { return "Transcription is charged in credits at its actual cost (usually a few)." }
            let expected = AIPricing.estimateCredits(inputTokens: tokens, maxOutputTokens: maxOut)
            let held = AIPricing.relayReservation(inputCharacters: chars, images: pictures, maxOutputTokens: maxOut)
            let balance = await MainActor.run { AICreditMeter.shared.balance }
            return "Up to \(expected.formatted()) credits (\(held.formatted()) held while it runs; only the actual cost is charged)" + (balance.map { "; you have \($0.formatted())." } ?? ".")
        case .openai, .gemini:
            return nil
        }
    }

    /// K8 — the longest the person waits for a reply.
    static let replyDeadline: Duration = .seconds(120)

    // MARK: - Plan A: the whole-case read (owner, 2026-11-04)
    //
    // The case's cleared documents as a cached prefix, the question after it. The person's consent is
    // the permission they gave for THIS case's document set (asked once per case, not per send); every
    // other step of `send` runs: eligibility, masking (the prefix masked first so it does not change with
    // the question), protected identities, the daily limit, the re-clearance of every document, the
    // record before the send, the deadline, the log, unmasking. The usage goes to the billing layer.

    /// The longest a whole-case read may take (a large case is read before the answer is written).
    static let caseReadDeadline: Duration = .seconds(300)
    /// Separates the case's blocks while they are masked as one text (no masking pattern matches it).
    static let blockSeparator = "\u{1E}\u{1E}case-block\u{1E}\u{1E}"

    public func readCase(_ request: CaseReadSend) async throws -> (text: String, usage: CloudCallUsage?) {
        let settings = seams.settings()
        let kind = settings.kind
        let model = settings.model
        if let why = OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: settings.confirmedDocumentTerms) {
            await log(kind, model, "", 0, 0, nil, "blocked", "provider not eligible for documents")
            throw await fail(OnlineError.notEligibleForDocuments(why))
        }
        guard await isAvailable(), let key = settings.apiKey else { throw await fail(OnlineError.notAvailable) }
        // The clearance must be the case's own (bound to its scope) and the person must have allowed
        // exactly the documents it clears — recomputed here, never taken from the caller.
        guard let binding = request.clearance.binding, binding.scopeID == request.caseID,
              !request.clearance.clearedObjectIDs.isEmpty else {
            await log(kind, model, "", 0, 0, nil, "blocked", "case read without the case's clearance")
            throw await fail(OnlineError.documentsNotCleared)
        }
        let fingerprint = CaseReadPermission.fingerprint(caseID: request.caseID, versions: request.clearance.versions)
        guard seams.casePermission(request.caseID, fingerprint) else {
            await log(kind, model, "", 0, 0, nil, "blocked", "no case permission for these documents")
            throw await fail(OnlineError.caseNotPermitted)
        }

        // K9 + masking: instructions written inside documents are defanged; the case text is masked
        // first and the question continues its placeholders.
        let guardInjection = PromptInjectionGuard()
        var prefix = request.prefix.map { guardInjection.defang($0) }
        var suffix = request.suffix
        var mapping: [String: String] = [:]
        let protected: [String]
        do { protected = try await protectedNames() } catch {
            await log(kind, model, "", 0, 0, nil, "blocked", "protected-identity register unreadable")
            throw await fail(OnlineError.protectionUnreadable)
        }
        var maskNames = protected
        if ProductModuleFlags.isEnabled(.onlinePIIMasking) { maskNames += await knownNames() }
        if !maskNames.isEmpty {
            let masker = OnlinePIIMasker(names: maskNames)
            let p = masker.mask(prefix.joined(separator: Self.blockSeparator))
            let parts = p.text.components(separatedBy: Self.blockSeparator)
            if parts.count == prefix.count { prefix = parts } else {
                await log(kind, model, "", 0, 0, nil, "blocked", "case blocks could not be masked")
                throw await fail(OnlineError.documentsNotCleared)
            }
            let q = masker.mask(suffix, continuing: p.mapping)
            suffix = q.text
            mapping = q.mapping
        }
        let prefixText = prefix.joined(separator: "\n\n")
        let shownText = prefixText + "\n\n" + suffix
        let bytes = shownText.utf8.count
        // The outbound record keeps the case text ONCE per exact text sent (CaseLogRecord): later reads
        // of the same case text record the question and a reference to that full copy.
        func record(_ outcome: String, _ responseBytes: Int?, _ detail: String?) async {
            let r = (try? await caseLogRecord(prefixText: prefixText, suffix: suffix, shownText: shownText,
                                              caseID: request.caseID, fingerprint: fingerprint))
                ?? CaseLogRecord(payload: shownText, sha: Self.sha256(shownText), tag: nil)
            await log(kind, model, r.payload, bytes, mapping.count, responseBytes, outcome,
                      [detail, r.tag].compactMap { $0 }.joined(separator: "; "), sha: r.sha)
        }
        let survivors = RedactionVerifier().leaks(in: shownText, protectedTerms: protected, artifact: "request")
        if !survivors.isEmpty {
            await record("blocked", nil, "protected source identity")
            throw await fail(OnlineError.protectedIdentity(survivors.count))
        }
        if ProductModuleFlags.isEnabled(.leastDataOnline), let cap = settings.dailyByteCap {
            let used = (try? await outboundLog?.bytesSentToday()) ?? 0
            if used + bytes > cap {
                await record("blocked", nil, "daily limit")
                throw await fail(OnlineError.limitReached(cap))
            }
        }
        // A6/B4 — every document is re-cleared at the send: still in the case, same version, not
        // privileged or restricted since the clearance.
        if let why = await request.clearance.stillCleared() {
            await record("blocked", nil, "sources changed before the case read")
            throw await fail(OnlineError.changedDuringConsent(why))
        }
        if Task.isCancelled {
            await record("cancelled", nil, "before sending")
            throw CancellationError()
        }
        // K8 — no record, no send: the lookup of the earlier full copy is part of writing the record.
        do {
            let r = try await caseLogRecord(prefixText: prefixText, suffix: suffix, shownText: shownText,
                                            caseID: request.caseID, fingerprint: fingerprint)
            try await recordPending(kind, model, r.payload, mapping.count, sha: r.sha, detail: r.tag)
        } catch { throw await fail(OnlineError.logUnavailable) }

        var dispatched = false
        do {
            // The person allowed this case's documents with the read's estimate shown (CaseReadPermission,
            // checked above), so on AI Included the read is a confirmed large read: the relay applies the
            // plan's case-read ceiling instead of the ordinary per-request one.
            let largeRead = kind == .included
            let outbound = try AIIncludedRelay.$confirmedLargeRead.withValue(largeRead) {
                try OnlineRequestBuilder.buildCaseReading(
                    kind: kind, model: model, apiKey: key, system: nil, prefix: prefix, suffix: suffix,
                    replyTokens: request.replyTokens, ttl: request.ttl, effort: request.effort)
            }
            try Task.checkCancellation()
            dispatched = true
            let response = try await AIIncludedRelay.$confirmedLargeRead.withValue(largeRead) {
                try await Self.withDeadline(Self.caseReadDeadline) { [seams] in try await seams.transport(outbound) }
            }
            if kind == .included, response.status >= 400, let why = AIIncludedRelay.refusal(in: response.body) {
                throw OnlineRequestBuilder.ParseError.relay(why)
            }
            let text = try OnlineRequestBuilder.parse(kind: kind, response: response)
            if kind == .included { AICreditMeter.recordReceipt(responseBody: response.body) }
            let usage = OnlineRequestBuilder.usage(kind: kind, response: response, purpose: request.purpose)
            await record("sent", response.body.count, "case read \(request.purpose)")
            if let usage { CloudUsageMeter.report(usage) }
            return (OnlinePIIMasker.unmask(text, mapping: mapping), usage)
        } catch is CancellationError {
            await record("cancelled", nil, dispatched ? "stopped waiting; delivery unknown" : "before sending")
            throw CancellationError()
        } catch {
            await record("failed", nil, error.localizedDescription)
            throw await fail(error)
        }
    }

    /// What one case-read entry of the outbound record holds.
    struct CaseLogRecord: Sendable {
        /// The full text sent, or — when that exact case text is already recorded in full — a reference
        /// to the full copy (case, document set, SHA-256 and size of the case text) and the task after it.
        let payload: String
        /// SHA-256 of exactly what left the Mac (always the full text, also on a reference entry).
        let sha: String
        /// The marker the full copy is found by ("case text <sha> (full copy)") or a reference's.
        let tag: String?
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func caseTextFullTag(_ digest: String) -> String { "case text \(digest) (full copy)" }

    /// Plan A — the case text is recorded ONCE per exact text sent (its SHA-256: the case's masked,
    /// defanged documents — so a new document set, a new version or a different masking stores a new
    /// full copy); later reads of the same text record the task and a reference to the first copy.
    /// Throws when the record cannot be read (the caller refuses to send: no record, no send).
    func caseLogRecord(prefixText: String, suffix: String, shownText: String, caseID: UUID, fingerprint: String) async throws -> CaseLogRecord {
        guard let outboundLog else { throw OnlineError.logUnavailable }
        let digest = Self.sha256(prefixText)
        let sha = Self.sha256(shownText)
        let full = Self.caseTextFullTag(digest)
        guard try await outboundLog.hasEntry(detailContaining: full) else {
            return CaseLogRecord(payload: shownText, sha: sha, tag: full)
        }
        let reference = "[Case text not repeated: identical to the full copy recorded earlier in this log — case \(caseID.uuidString), document set \(fingerprint.prefix(16)), case text SHA-256 \(digest), \(prefixText.utf8.count) bytes. The task sent after it follows.]"
        return CaseLogRecord(payload: reference + "\n\n" + suffix, sha: sha, tag: "case text \(digest) (see the full copy)")
    }

    /// Run `op`, failing with `.timedOut` after `deadline` and with `CancellationError` when the caller
    /// is cancelled — even if `op` itself never returns (an XPC reply that never comes).
    static func withDeadline<T: Sendable>(_ deadline: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        // A7 — the work runs in a task this wrapper owns: a timeout or the caller's cancel CANCELS it
        // (not only stops waiting for it), so the transport sees the cancel and stops.
        let once = DeadlineResume<T>()
        let work = Task { try await op() }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            work.cancel()
            once.resume(.failure(OnlineError.timedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                once.attach(c)
                Task {
                    let result = await work.result
                    timer.cancel()
                    once.resume(result)
                }
            }
        } onCancel: {
            work.cancel()
            timer.cancel()
            once.resume(.failure(CancellationError()))
        }
    }

    /// `sha`: the SHA-256 of what is sent when `text` is not all of it (a case read's reference entry).
    func recordPending(_ kind: OnlineProviderKind, _ model: String, _ text: String, _ masked: Int,
                       sha: String? = nil, detail: String? = nil) async throws {
        guard let outboundLog else { throw OnlineError.logUnavailable }
        try await outboundLog.record(OutboundLogEntry(
            id: UUID(), sentAt: Date(), provider: kind.rawValue, model: model, host: kind.host,
            bytesSent: 0, maskedCount: masked, payloadSHA256: sha ?? Self.sha256(text), payloadText: text, responseBytes: nil,
            outcome: "sending", detail: detail))
    }

    /// Embeddings never leave the Mac: this provider has no `.embedding` capability.
    public func embed(text: String) async throws -> [Float] {
        throw ModelProviderError.unavailable(providerID: id)
    }

    private func fail(_ error: Error) async -> Error {
        let reason = OnlineFailure.scrubbed(error.localizedDescription)
        let kind = OnlineFailure.classify(error)
        KalsmritikoshLog.routing.error("Online answer failed (\(kind.rawValue, privacy: .public)): \(reason, privacy: .public)")
        await MainActor.run { OnlineStatus.shared.recordFailure(reason, kind: kind) }
        return error
    }

    private func log(_ kind: OnlineProviderKind, _ model: String, _ text: String, _ bytes: Int, _ masked: Int,
                     _ responseBytes: Int?, _ outcome: String, _ detail: String?, sha: String? = nil) async {
        guard let outboundLog else { return }
        let sha = sha ?? Self.sha256(text)
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

    init(cloudAllowed: Bool, kind: OnlineProviderKind, model: String, keyDigest: String?, documentsEligible: Bool) {
        self.cloudAllowed = cloudAllowed; self.kind = kind; self.model = model; self.keyDigest = keyDigest
        self.documentsEligible = documentsEligible
    }

    /// The settings of a snapshot, the key reduced to its digest.
    init(_ s: OnlineSnapshot) {
        self.init(cloudAllowed: s.cloudAllowed, kind: s.kind, model: s.model,
                  keyDigest: s.apiKey.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() },
                  documentsEligible: OnlineDocumentEligibility.refusal(kind: s.kind, confirmedTermsVersion: s.confirmedDocumentTerms) == nil)
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

/// The Online settings a send reads, taken at one moment.
public nonisolated struct OnlineSnapshot: Sendable, Equatable {
    public var cloudAllowed: Bool
    public var kind: OnlineProviderKind
    public var model: String
    public var apiKey: String?
    public var confirmedDocumentTerms: String?
    public var dailyByteCap: Int?
    public init(cloudAllowed: Bool, kind: OnlineProviderKind, model: String, apiKey: String?,
                confirmedDocumentTerms: String?, dailyByteCap: Int?) {
        self.cloudAllowed = cloudAllowed; self.kind = kind; self.model = model; self.apiKey = apiKey
        self.confirmedDocumentTerms = confirmedDocumentTerms; self.dailyByteCap = dailyByteCap
    }
    public static func current() -> OnlineSnapshot {
        let kind = OnlineSettings.kind
        return OnlineSnapshot(cloudAllowed: OnlineSettings.cloudAllowed, kind: kind, model: OnlineSettings.model,
                              apiKey: OnlineSettings.apiKey(for: kind), confirmedDocumentTerms: OnlineSettings.confirmedDocumentTerms(for: kind),
                              dailyByteCap: OnlineSettings.dailyByteCap)
    }
}
