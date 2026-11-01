//
//  OnlineProviderKind.swift
//  Kalsmritikosh
//
//  O-4 — the three bring-your-own-key cloud providers Online mode supports, and
//  how to build each one's HTTPS request and read its reply. Model names live
//  here (Routing/Providers) by the capability-discipline rule.
//
//  Nothing in this file touches the network: it produces a request envelope the
//  separate network helper sends (O-2), and parses the bytes it returns.
//

import Foundation

public nonisolated enum OnlineProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic, openai, gemini
    /// A2 — AI Included: Claude Opus 5 through the publisher's relay, for AI Included subscribers.
    /// Its "key" is the App Store subscription number; the publisher's provider key never reaches the Mac.
    case included

    public var id: String { rawValue }

    /// Offered in Settings: AI Included only when this build has the relay's address.
    public var isSelectable: Bool { self != .included || (AIIncludedRelay.isConfigured && AIRegion.allowsAI) }

    /// The person brings their own key and chooses the model (false for AI Included).
    public var usesOwnKey: Bool { self != .included }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "OpenAI"
        case .gemini:    return "Gemini (Google)"
        case .included:  return "AI Included (Claude Opus 5)"
        }
    }

    /// The only host each provider may be sent to. The network helper enforces
    /// the same allowlist on its side.
    public var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai:    return "api.openai.com"
        case .gemini:    return "generativelanguage.googleapis.com"
        case .included:  return AIIncludedRelay.host
        }
    }

    /// Prefilled model name; the user can change it in Settings.
    public var defaultModel: String {
        switch self {
        case .anthropic, .included: return "claude-opus-5"
        case .openai:    return ""
        case .gemini:    return ""
        }
    }

    public static let allowedHosts: Set<String> = Set(allCases.map(\.host).filter { !$0.isEmpty })
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
            case .audioNotSupported(let p): return "\(p) does not transcribe recordings. Choose AI Included, or Gemini with your own key, in Settings ▸ Online — nothing was sent."
            }
        }
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
            // The relay fixes the model and the output ceiling itself; it reads only these fields.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": max(1024, min(maxTokens, 4096)),
                "messages": [["role": "user", "content": anthropicContent]]
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return try AIIncludedRelay.request("/v1/messages", subscription: apiKey, body: body)
        case .anthropic:
            // Messages API. No sampling parameters (rejected on current models);
            // server-side fallbacks on refusal, per Anthropic's guidance for this model.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": max(1024, min(maxTokens, 16_000)),
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
            return "AI Included sends the request through the publisher's relay under the publisher's account: questions, passages and page images to Anthropic's commercial API (Claude Opus 5; if Anthropic declines a request, another Claude model may answer it), and recordings to Google's paid Gemini API for transcription. The relay keeps only counts (questions used, money spent) — never a question, passage, image, recording or answer. The providers' commercial terms apply: Anthropic deletes inputs and outputs within 30 days by default, with exceptions for usage-policy enforcement and legal requirements; neither provider uses them for training."
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
