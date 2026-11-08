//
//  OnlineProviderKind.swift
//  Kalsmritikosh
//
//  O-4 — the cloud providers Online mode can talk to, and how to build each one's
//  HTTPS request and read its reply. Model names live here (Routing/Providers) by
//  the capability-discipline rule.
//
//  Release decisions 2026-11-04 (item 4): the person's OWN key answers with Anthropic (Claude) only.
//  OpenAI and Gemini are no longer offered as answering providers (`isSelectable` false, their hosts
//  are not allowed, a stored choice of either migrates to "not set up" — OnlineSettings.kind). Their
//  cases stay because `.gemini` is the reply format of the relay's transcription route (AI plans) and
//  the request/parse code is pinned by builder tests; nothing in the release reaches them.
//
//  Nothing in this file touches the network: it produces a request envelope the
//  separate network helper sends (O-2), and parses the bytes it returns.
//

import Foundation

public nonisolated enum OnlineProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic, openai, gemini
    /// A2 — AI Included / AI Pro: Claude Opus 5.5 through the publisher's relay, metered in credits.
    /// Its "key" is the App Store subscription number; the publisher's provider key never reaches the Mac.
    case included

    public var id: String { rawValue }

    /// Offered in Settings: the own key is Claude (Anthropic) only, and not where the App Store country
    /// blocks Online AI; AI Included only when this build has the relay's address and the country is
    /// confirmed as allowed. OpenAI and Gemini are never offered (release decisions 2026-11-04).
    public var isSelectable: Bool {
        switch self {
        case .anthropic:        return !AIRegion.isBlocked
        case .included:         return AIIncludedRelay.isConfigured && AIRegion.allowsAI
        case .openai, .gemini:  return false
        }
    }

    /// Retired as answering providers (release decisions 2026-11-04): a stored choice of one of these is
    /// migrated to "not set up" (OnlineSettings.kind).
    public var isRetiredForAnswering: Bool { self == .openai || self == .gemini }

    /// The person brings their own key and chooses the model (false for AI Included).
    public var usesOwnKey: Bool { self != .included }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "OpenAI"
        case .gemini:    return "Gemini (Google)"
        case .included:  return "AI Included or AI Pro (Claude Opus 5.5)"
        }
    }

    /// The only host each provider may be sent to. The network helper enforces
    /// the same allowlist on its side.
    public var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai:    return "api.openai.com"
        case .gemini:    return "generativelanguage.googleapis.com"
        case .included:  return AIIncludedRelay.activeHost
        }
    }

    /// Prefilled model name; the user can change it in Settings.
    public var defaultModel: String {
        switch self {
        // Own key: Claude Opus 5 (unchanged). AI plans: the relay's model (AIPricing.relayModel, Opus 5.5 —
        // the relay fixes the model itself; this is what the app estimates and names).
        case .anthropic: return "claude-opus-5"
        case .included:  return AIPricing.relayModel
        case .openai:    return ""
        case .gemini:    return ""
        }
    }

    /// The AI hosts a request may go to: Anthropic (own key) and the publisher's relay (AI plans). The
    /// retired providers' hosts are not allowed (the network helper applies the same list).
    public static let allowedHosts: Set<String> = Set(allCases.filter { !$0.isRetiredForAnswering }.map(\.host).filter { !$0.isEmpty })
}

/// A fully built request, handed to the network helper as JSON.
public nonisolated struct OutboundHTTPRequest: Codable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let body: Data
    /// A8–A10 — "GET" for public-record lookups and web capture; nil = POST (the AI providers).
    public var method: String? = nil
    /// A9 — "capture": a page the person asked to capture (any HTTPS host, GET only).
    public var purpose: String? = nil
    public init(url: String, headers: [String: String], body: Data, method: String? = nil, purpose: String? = nil) {
        self.url = url; self.headers = headers; self.body = body; self.method = method; self.purpose = purpose
    }
}

/// A4 — one page image sent for reading (JPEG or PNG), alongside the text prompt.
public nonisolated struct OutboundImage: Sendable, Equatable {
    public let mediaType: String   // "image/jpeg" or "image/png"
    public let data: Data
    public let label: String       // e.g. "page 3", shown in the preview and the outbound record
    public init(mediaType: String, data: Data, label: String) {
        self.mediaType = mediaType; self.data = data; self.label = label
    }
}

public nonisolated struct OutboundHTTPResponse: Codable, Sendable {
    public let status: Int
    public let body: Data
}

public nonisolated enum OnlineRequestBuilder {

    public enum BuildError: Error, LocalizedError, Equatable {
        case imagesNotSupported(String), audioNotSupported(String)
        public var errorDescription: String? {
            switch self {
            case .imagesNotSupported(let p): return "\(p) is not set up to read page images in this release — nothing was sent."
            case .audioNotSupported(let p): return "\(p) does not transcribe recordings. Transcription is part of the AI plans: choose AI Included or AI Pro in Settings ▸ Online — nothing was sent."
            }
        }
    }

    /// The thinking allowance added to a Claude request's reply budget (billed only as used).
    public static let anthropicThinkingAllowance = 8_000

    /// max_tokens for a Claude request: the reply's budget (at least 1,024, at most 16,000) plus the
    /// thinking allowance.
    public static func anthropicMaxTokens(_ replyTokens: Int) -> Int {
        max(1024, min(replyTokens, 16_000)) + anthropicThinkingAllowance
    }

    public static func build(kind: OnlineProviderKind, model: String, apiKey: String,
                             system: String?, prompt: String, maxTokens: Int,
                             images: [OutboundImage] = []) throws -> OutboundHTTPRequest {
        // A4 — page images go first, then the instruction (the order Anthropic recommends).
        let anthropicContent: Any = images.isEmpty ? prompt as Any :
            images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]] as [String: Any] }
            + [["type": "text", "text": prompt]]
        let geminiParts: [[String: Any]] = images.map { ["inline_data": ["mime_type": $0.mediaType, "data": $0.data.base64EncodedString()]] }
            + [["text": prompt]]
        if !images.isEmpty, kind == .openai { throw BuildError.imagesNotSupported(kind.displayName) }
        // A11 — a recording: Gemini reads audio directly; AI Included sends it to the relay's transcription
        // route (Gemini on the publisher's key, its own fixed prompt); Claude does not take audio.
        if let audio = images.first(where: { $0.mediaType.hasPrefix("audio/") || $0.mediaType.hasPrefix("video/") }) {
            switch kind {
            case .included:
                return try AIIncludedRelay.request("/v1/transcribe", subscription: apiKey,
                                                   body: ["audioBase64": audio.data.base64EncodedString(), "mimeType": audio.mediaType])
            case .gemini: break
            case .anthropic, .openai: throw BuildError.audioNotSupported(kind.displayName)
            }
        }
        switch kind {
        case .included:
            // The relay fixes the model and the output ceiling itself (24,000); it reads only these fields.
            // The reply budget gets the same thinking allowance as a Claude request with an own key.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": anthropicMaxTokens(maxTokens),
                "messages": [["role": "user", "content": anthropicContent]]
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return try AIIncludedRelay.request("/v1/messages", subscription: apiKey, body: body)
        case .anthropic:
            // Messages API. No sampling parameters (rejected on current models);
            // server-side fallbacks on refusal, per Anthropic's guidance for this model.
            // Current models think before they answer (on by default) and the thinking counts against
            // max_tokens: `maxTokens` is the reply's own budget, the thinking allowance comes on top
            // (smoke 2026-11-03: a 1,500-token draft call spent all 1,500 on thinking, no reply text).
            var body: [String: Any] = [
                "model": model,
                "max_tokens": anthropicMaxTokens(maxTokens),
                "messages": [["role": "user", "content": anthropicContent]],
                "fallbacks": "default"
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return OutboundHTTPRequest(
                url: "https://\(kind.host)/v1/messages",
                headers: ["content-type": "application/json",
                          "x-api-key": apiKey,
                          "anthropic-version": "2023-06-01",
                          "anthropic-beta": "server-side-fallback-2026-07-01"],
                body: try JSONSerialization.data(withJSONObject: body))
        case .openai:
            var messages: [[String: Any]] = []
            if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": prompt])
            let body: [String: Any] = ["model": model, "messages": messages,
                                       "max_completion_tokens": max(256, min(maxTokens, 16_000))]
            return OutboundHTTPRequest(
                url: "https://\(kind.host)/v1/chat/completions",
                headers: ["content-type": "application/json", "authorization": "Bearer \(apiKey)"],
                body: try JSONSerialization.data(withJSONObject: body))
        case .gemini:
            var body: [String: Any] = [
                "contents": [["role": "user", "parts": geminiParts]],
                "generationConfig": ["maxOutputTokens": max(256, min(maxTokens, 16_000))]
            ]
            if let system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
            let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            return OutboundHTTPRequest(
                url: "https://\(kind.host)/v1beta/models/\(escaped):generateContent",
                headers: ["content-type": "application/json", "x-goog-api-key": apiKey],
                body: try JSONSerialization.data(withJSONObject: body))
        }
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case http(Int, String), refused(String), unreadable
        /// The reply hit the output limit before any answer text was written (the budget went to thinking).
        case cutOff(String)
        /// A2 — the AI Included service declined (questions used up, paused for the month, not subscribed…).
        case relay(String)
        /// K8 — 401/403: the key was refused; retrying will not help.
        case auth(Int)
        /// K8 — 429: the provider is limiting requests; try again later.
        case rateLimited
        /// K8 — 5xx: the provider failed; nothing was answered.
        case server(Int)
        public var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "The provider returned HTTP \(code): \(msg)"
            case .refused(let why):        return "The provider declined to answer: \(why)"
            case .unreadable:              return "The provider's reply could not be read."
            case .cutOff(let detail):      return "The provider's reply was cut off at the output limit before any answer text (\(detail))."
            case .relay(let why):          return why
            case .auth(let code):          return "The provider refused the API key (HTTP \(code)). Check the key and its access in Settings › Online."
            case .rateLimited:             return "The provider is limiting requests right now (HTTP 429). Nothing was answered; try again in a minute."
            case .server(let code):        return "The provider had an error (HTTP \(code)). Nothing was answered; try again later."
            }
        }
    }

    public static func parse(kind: OnlineProviderKind, response: OutboundHTTPResponse) throws -> String {
        let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if kind == .included, response.status >= 400, let why = AIIncludedRelay.refusal(in: response.body) {
            throw ParseError.relay(why)
        }
        switch response.status {
        case 401, 403: throw ParseError.auth(response.status)
        case 429: throw ParseError.rateLimited
        case 500...: throw ParseError.server(response.status)
        case 400...:
            // The provider's own message, short — never the request it echoes back.
            let message = ((root?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: response.body.prefix(300), encoding: .utf8) ?? ""
            throw ParseError.http(response.status, String(message.prefix(200)))
        default: break
        }
        guard let root else { throw ParseError.unreadable }
        switch kind {
        case .anthropic, .included:
            if root["stop_reason"] as? String == "refusal" {
                let detail = (root["stop_details"] as? [String: Any])?["explanation"] as? String
                throw ParseError.refused(detail ?? "refusal")
            }
            let blocks = root["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            if text.isEmpty, root["stop_reason"] as? String == "max_tokens" {
                let usage = root["usage"] as? [String: Any]
                let output = usage?["output_tokens"] as? Int ?? 0
                let thinking = (usage?["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0
                throw ParseError.cutOff("\(output) output tokens, \(thinking) of them thinking")
            }
            guard !text.isEmpty else { throw ParseError.unreadable }
            return text
        case .openai:
            guard let choices = root["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else { throw ParseError.unreadable }
            if let refusal = msg["refusal"] as? String, !refusal.isEmpty { throw ParseError.refused(refusal) }
            if choices.first?["finish_reason"] as? String == "content_filter" { throw ParseError.refused("content filter") }
            guard let text = msg["content"] as? String, !text.isEmpty else { throw ParseError.unreadable }
            return text
        case .gemini:
            if let block = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String { throw ParseError.refused(block) }
            if let reason = (root["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String,
               ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(reason) { throw ParseError.refused(reason) }
            guard let cands = root["candidates"] as? [[String: Any]],
                  let content = cands.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw ParseError.unreadable }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw ParseError.unreadable }
            return text
        }
    }
}

// MARK: - Why a call failed, in the person's words (real-case v2 interim review 2026-11-04, item 7)
//
// The answer said "the AI reader did not answer" while the provider had said "HTTP 400: Your credit
// balance is too low to access the Anthropic API" — only the run summary knew. Every failure is
// classified here, next to the parse that produced it, so the answer's note and the Online status bar
// can say what happened and what to do. Never the key: anything shaped like one is hidden.

public nonisolated enum OnlineFailure: String, Sendable, Equatable, CaseIterable {
    case noCredit, invalidKey, rateLimited, network, timeout, cutOff, declined, refused, providerError, notSent, unreadable, other

    /// Anthropic: a too-low credit balance comes back as 400 invalid_request_error with this message;
    /// billing problems as 402 billing_error. Other providers word it as quota / billing.
    static let creditPattern = #"(?i)credit balance|insufficient (?:credit|funds|balance|quota)|billing|purchase credits|exceeded your current quota|payment required"#
    static let keyPattern = #"(?i)invalid (?:x-)?api[- ]?key|api key not valid|incorrect api key|authentication_error|permission_error|unauthori[sz]ed"#

    public static func classify(_ error: Error) -> OnlineFailure {
        if let p = error as? OnlineRequestBuilder.ParseError {
            switch p {
            case .auth: return .invalidKey
            case .rateLimited: return .rateLimited
            case .server: return .providerError
            case .cutOff: return .cutOff
            case .refused: return .refused
            case .unreadable: return .unreadable
            case .relay(let why): return classify(text: why) ?? .other
            case .http(let code, let message):
                if code == 402 { return .noCredit }
                return classify(text: message) ?? (code == 408 ? .timeout : .other)
            }
        }
        if let o = error as? OnlineCloudProvider.OnlineError {
            switch o {
            case .timedOut: return .timeout
            case .declined: return .declined
            default: return .notSent
            }
        }
        if error is NetworkHelperError { return .network }
        if let u = error as? URLError { return u.code == .timedOut ? .timeout : .network }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        return classify(text: (error as? LocalizedError)?.errorDescription ?? String(describing: error)) ?? .other
    }

    static func classify(text: String) -> OnlineFailure? {
        if text.range(of: creditPattern, options: .regularExpression) != nil { return .noCredit }
        if text.range(of: keyPattern, options: .regularExpression) != nil { return .invalidKey }
        if text.range(of: #"(?i)rate[_ ]limit|too many requests"#, options: .regularExpression) != nil { return .rateLimited }
        if text.range(of: #"(?i)overloaded"#, options: .regularExpression) != nil { return .providerError }
        if text.range(of: #"(?i)timed out|deadline"#, options: .regularExpression) != nil { return .timeout }
        return nil
    }

    /// What the person is told, in the answer's note ("The AI reading could not be used — …").
    public var summary: String {
        switch self {
        case .noCredit:      return "your AI account has no credit left — top it up with the provider; until then answers are evidence-only"
        case .invalidKey:    return "the provider refused your API key — check the key in Settings › Online"
        case .rateLimited:   return "the provider is limiting requests right now — try again in a minute"
        case .network:       return "this Mac could not reach the provider (network)"
        case .timeout:       return "the provider did not reply in time"
        case .cutOff:        return "the provider's reply was cut off before any answer text"
        case .declined:      return "you chose not to send it"
        case .refused:       return "the provider declined to answer"
        case .providerError: return "the provider had an error"
        case .notSent:       return "nothing was sent"
        case .unreadable:    return "the provider's reply could not be read"
        case .other:         return "the AI reader did not answer"
        }
    }

    /// A problem with the person's account that lasts beyond one question: shown as a banner until dismissed.
    public var banner: String? {
        switch self {
        case .noCredit:   return "Your AI account has no credit — answers are evidence-only until it is topped up."
        case .invalidKey: return "Your AI provider refused the API key — answers are evidence-only until the key in Settings › Online is fixed."
        default:          return nil
        }
    }

    /// The answer's note: the classified reason and the provider's own short words (key-shaped text hidden).
    public static func note(for error: Error) -> String {
        let kind = classify(error)
        let detail = scrubbed((error as? LocalizedError)?.errorDescription ?? "")
        guard !detail.isEmpty, [.noCredit, .invalidKey, .rateLimited, .providerError, .refused, .other].contains(kind) else { return kind.summary }
        return kind.summary + " (the provider said: \u{201C}" + String(detail.prefix(160)) + "\u{201D})"
    }

    /// Anything shaped like an API key replaced, whitespace squashed.
    public static func scrubbed(_ s: String) -> String {
        var out = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for pattern in [#"sk-[A-Za-z0-9_\-]{8,}"#, #"AIza[0-9A-Za-z_\-]{20,}"#, #"(?i)(?:x-api-key|api[_-]?key|bearer)\s*[:=]?\s*[A-Za-z0-9_\-\.]{16,}"#] {
            out = out.replacingOccurrences(of: pattern, with: "[key hidden]", options: .regularExpression)
        }
        return out
    }
}

// MARK: - Which providers may receive case documents (ship-readiness review L2)
//
// Sending a person's documents is not the same decision as sending a question. An opt-in switch is not
// enough: the provider's own terms decide whether confidential case material may go to it at all. Each
// provider carries the terms as reviewed on `documentTermsVersion`; the person confirms that their own
// account is on those terms, and the confirmation lapses when the reviewed terms change. A provider whose
// terms have not been reviewed for case material receives no documents.

nonisolated extension OnlineProviderKind {

    /// The date the terms below were reviewed. A confirmation given against an older text lapses.
    public var documentTermsVersion: String { "2026-10-27" }

    /// false = no document excerpts are sent to this provider in this release.
    public var mayReceiveDocuments: Bool {
        switch self {
        case .anthropic, .gemini, .included: return true
        case .openai:                        return false
        }
    }

    /// What the provider does with what it receives, shown in Settings and on every document send.
    public var documentTerms: String {
        switch self {
        case .anthropic:
            return "Anthropic's commercial API: by default, inputs and outputs are deleted within 30 days, with exceptions for usage-policy enforcement and legal requirements; zero retention needs a separate agreement. Under the commercial terms they are not used for training. This app's publisher receives nothing — that does not mean the provider keeps nothing."
        case .gemini:
            return "Google Gemini API: only a PAID (billing-enabled) project. On the unpaid tier Google may use what you send to improve its products, including human review, and asks that sensitive or confidential information not be sent — case documents must not go to an unpaid key. Age, region and permitted-use conditions apply."
        case .included:
            return "AI Included sends the request through the publisher's relay under the publisher's account: questions, passages and page images to Anthropic's commercial API (Claude Opus 5.5; if Anthropic declines a request, another Claude model may answer it), and recordings to Google's paid Gemini API for transcription. The relay keeps only counts and credits (credits used and left, the service's total spend) — never a question, passage, image, recording or answer. The providers' commercial terms apply: Anthropic deletes inputs and outputs within 30 days by default, with exceptions for usage-policy enforcement and legal requirements; Google's paid Gemini API keeps prompts and replies for a limited period only to detect abuse and misuse; neither provider uses them for training."
        case .openai:
            return "OpenAI: its API data-use and retention terms have not been reviewed for case material in this release, so no document text is sent to it. Questions alone may still be sent."
        }
    }

    /// What the person confirms before their documents may go to this provider.
    public var documentAttestation: String {
        switch self {
        case .anthropic: return "My Anthropic account is on the commercial API terms, and I may send this case material to it"
        case .gemini:    return "My Gemini key belongs to a paid (billing-enabled) project, and I may send this case material to it"
        case .included:  return "I may send this case material to Anthropic's and Google's commercial APIs through AI Included"
        case .openai:    return ""
        }
    }
}

public nonisolated enum OnlineDocumentEligibility {
    /// nil when document excerpts may go to `kind` given the recorded confirmation; otherwise why not.
    public static func refusal(kind: OnlineProviderKind, confirmedTermsVersion: String?) -> String? {
        guard kind.mayReceiveDocuments else {
            return "\(kind.displayName) is not reviewed for case documents in this release — no document text was sent."
        }
        guard confirmedTermsVersion == kind.documentTermsVersion else {
            return confirmedTermsVersion == nil
                ? "Confirm in Settings ▸ Online that your \(kind.displayName) account's terms permit sending case material — no document text was sent."
                : "The reviewed \(kind.displayName) terms changed since you confirmed them; confirm again in Settings ▸ Online — no document text was sent."
        }
        return nil
    }
}
