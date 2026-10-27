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

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "OpenAI"
        case .gemini:    return "Gemini (Google)"
        }
    }

    /// The only host each provider may be sent to. The network helper enforces
    /// the same allowlist on its side.
    public var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai:    return "api.openai.com"
        case .gemini:    return "generativelanguage.googleapis.com"
        }
    }

    /// Prefilled model name; the user can change it in Settings.
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5"
        case .openai:    return ""
        case .gemini:    return ""
        }
    }

    public static let allowedHosts: Set<String> = Set(allCases.map(\.host))
}

/// A fully built request, handed to the network helper as JSON.
public nonisolated struct OutboundHTTPRequest: Codable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let body: Data
}

public nonisolated struct OutboundHTTPResponse: Codable, Sendable {
    public let status: Int
    public let body: Data
}

public nonisolated enum OnlineRequestBuilder {

    public static func build(kind: OnlineProviderKind, model: String, apiKey: String,
                             system: String?, prompt: String, maxTokens: Int) throws -> OutboundHTTPRequest {
        switch kind {
        case .anthropic:
            // Messages API. No sampling parameters (rejected on current models);
            // server-side fallbacks on refusal, per Anthropic's guidance for this model.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": max(1024, min(maxTokens, 16_000)),
                "messages": [["role": "user", "content": prompt]],
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
                "contents": [["role": "user", "parts": [["text": prompt]]]],
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

    public enum ParseError: Error, LocalizedError {
        case http(Int, String), refused(String), unreadable
        public var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "The provider returned HTTP \(code): \(msg)"
            case .refused(let why):        return "The provider declined to answer: \(why)"
            case .unreadable:              return "The provider's reply could not be read."
            }
        }
    }

    public static func parse(kind: OnlineProviderKind, response: OutboundHTTPResponse) throws -> String {
        let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if response.status >= 400 {
            let message = ((root?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: response.body.prefix(300), encoding: .utf8) ?? ""
            throw ParseError.http(response.status, message)
        }
        guard let root else { throw ParseError.unreadable }
        switch kind {
        case .anthropic:
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
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String else { throw ParseError.unreadable }
            return text
        case .gemini:
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

extension OnlineProviderKind {

    /// The date the terms below were reviewed. A confirmation given against an older text lapses.
    public var documentTermsVersion: String { "2026-10-27" }

    /// false = no document excerpts are sent to this provider in this release.
    public var mayReceiveDocuments: Bool {
        switch self {
        case .anthropic, .gemini: return true
        case .openai:             return false
        }
    }

    /// What the provider does with what it receives, shown in Settings and on every document send.
    public var documentTerms: String {
        switch self {
        case .anthropic:
            return "Anthropic's commercial API: by default, inputs and outputs are deleted within 30 days, with exceptions for usage-policy enforcement and legal requirements; zero retention needs a separate agreement. Under the commercial terms they are not used for training. This app's publisher receives nothing — that does not mean the provider keeps nothing."
        case .gemini:
            return "Google Gemini API: only a PAID (billing-enabled) project. On the unpaid tier Google may use what you send to improve its products, including human review, and asks that sensitive or confidential information not be sent — case documents must not go to an unpaid key. Age, region and permitted-use conditions apply."
        case .openai:
            return "OpenAI: its API data-use and retention terms have not been reviewed for case material in this release, so no document text is sent to it. Questions alone may still be sent."
        }
    }

    /// What the person confirms before their documents may go to this provider.
    public var documentAttestation: String {
        switch self {
        case .anthropic: return "My Anthropic account is on the commercial API terms, and I may send this case material to it"
        case .gemini:    return "My Gemini key belongs to a paid (billing-enabled) project, and I may send this case material to it"
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
