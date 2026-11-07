//
//  CaseReadRequest.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — the request that reads a WHOLE case: the case's documents as a stable
//  prefix the provider caches, the question (or analysis task) after it. Kept apart from the general
//  `build` so the per-question path is unchanged.
//
//  Anthropic shape (Messages API):
//    messages[0].content = [ {text: document 1}, …, {text: document N, cache_control: {type: ephemeral[, ttl: 1h]}},
//                            {text: the task and question} ]
//    max_tokens = reply budget + thinking allowance; output_config.effort; server-side fallbacks.
//  Everything before the breakpoint depends only on the case's documents (no time, no question, no
//  ids that change per call), and the body is serialised with sorted keys, so two questions about the
//  same case send a byte-identical prefix and the second one is read from the cache.
//

import Foundation

public nonisolated enum CaseReadCacheTTL: String, Sendable, Codable {
    /// The default: five minutes, refreshed by every read.
    case fiveMinutes = "5m"
    /// While a case is open for interactive work (questions minutes apart).
    case oneHour = "1h"
}

public nonisolated enum CaseReadEffort: String, Sendable, Codable {
    case low, medium, high
}

extension OnlineRequestBuilder {
    /// The reply budget of a whole-case question (the thinking allowance comes on top).
    public static let caseReadReplyTokens = 2_000

    /// The text block that carries the cache breakpoint.
    static func cachedBlock(_ text: String, ttl: CaseReadCacheTTL) -> [String: Any] {
        var cache: [String: Any] = ["type": "ephemeral"]
        if ttl == .oneHour { cache["ttl"] = "1h" }
        return ["type": "text", "text": text, "cache_control": cache]
    }

    /// The Anthropic-form content: the case blocks (breakpoint on the last), then the task.
    static func caseReadContent(prefix: [String], suffix: String, ttl: CaseReadCacheTTL) -> [[String: Any]] {
        var content: [[String: Any]] = []
        for (i, block) in prefix.enumerated() {
            content.append(i == prefix.count - 1 ? cachedBlock(block, ttl: ttl) : ["type": "text", "text": block])
        }
        content.append(["type": "text", "text": suffix])
        return content
    }

    public static func buildCaseReading(kind: OnlineProviderKind, model: String, apiKey: String, system: String?,
                                        prefix: [String], suffix: String, replyTokens: Int, ttl: CaseReadCacheTTL,
                                        effort: CaseReadEffort) throws -> OutboundHTTPRequest {
        switch kind {
        case .anthropic:
            var body: [String: Any] = [
                "model": model,
                "max_tokens": anthropicMaxTokens(replyTokens),
                "messages": [["role": "user", "content": caseReadContent(prefix: prefix, suffix: suffix, ttl: ttl)]],
                "output_config": ["effort": effort.rawValue],
                "fallbacks": "default"
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return OutboundHTTPRequest(
                url: "https://\(kind.host)/v1/messages",
                headers: ["content-type": "application/json",
                          "x-api-key": apiKey,
                          "anthropic-version": "2023-06-01",
                          "anthropic-beta": "server-side-fallback-2026-07-01"],
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        case .included:
            // The relay fixes the model and the output ceiling; it forwards the content blocks (with their
            // cache breakpoint) and the effort. The billing layer may route this through a reservation.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": anthropicMaxTokens(replyTokens),
                "messages": [["role": "user", "content": caseReadContent(prefix: prefix, suffix: suffix, ttl: ttl)]],
                "output_config": ["effort": effort.rawValue]
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return try AIIncludedRelay.request("/v1/messages", subscription: apiKey, body: body)
        case .openai, .gemini:
            // No explicit cache breakpoints: the same text as one prompt (prefix first, so a provider-side
            // prefix cache can still apply).
            return try build(kind: kind, model: model, apiKey: apiKey, system: system,
                             prompt: (prefix + [suffix]).joined(separator: "\n\n"), maxTokens: replyTokens)
        }
    }

    /// The usage block of a reply (Anthropic form; nil when the reply carries none).
    public static func usage(kind: OnlineProviderKind, response: OutboundHTTPResponse, purpose: String) -> CloudCallUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { return nil }
        switch kind {
        case .anthropic, .included:
            guard let u = root["usage"] as? [String: Any] else { return nil }
            return CloudCallUsage(inputTokens: u["input_tokens"] as? Int ?? 0,
                                  cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                                  cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                                  outputTokens: u["output_tokens"] as? Int ?? 0, purpose: purpose, provider: kind.rawValue)
        case .openai:
            guard let u = root["usage"] as? [String: Any] else { return nil }
            let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            return CloudCallUsage(inputTokens: (u["prompt_tokens"] as? Int ?? 0) - cached, cacheWriteTokens: 0, cacheReadTokens: cached,
                                  outputTokens: u["completion_tokens"] as? Int ?? 0, purpose: purpose, provider: kind.rawValue)
        case .gemini:
            guard let u = root["usageMetadata"] as? [String: Any] else { return nil }
            let cached = u["cachedContentTokenCount"] as? Int ?? 0
            return CloudCallUsage(inputTokens: (u["promptTokenCount"] as? Int ?? 0) - cached, cacheWriteTokens: 0, cacheReadTokens: cached,
                                  outputTokens: u["candidatesTokenCount"] as? Int ?? 0, purpose: purpose, provider: kind.rawValue)
        }
    }
}

/// One whole-case read handed to `OnlineCloudProvider.readCase`.
public nonisolated struct CaseReadSend: Sendable {
    public let caseID: UUID
    /// The case's blocks, stable across questions (the cache breakpoint goes on the last one).
    public let prefix: [String]
    /// The task and question, after the cached prefix.
    public let suffix: String
    public let replyTokens: Int
    public let ttl: CaseReadCacheTTL
    public let effort: CaseReadEffort
    /// "case.question" or "case.analysis" — recorded with the usage.
    public let purpose: String
    /// The case's documents as cleared by CloudSourceGate bound to the case's scope.
    public let clearance: CloudSourceClearance
    public init(caseID: UUID, prefix: [String], suffix: String, replyTokens: Int = OnlineRequestBuilder.caseReadReplyTokens,
                ttl: CaseReadCacheTTL, effort: CaseReadEffort = .high, purpose: String, clearance: CloudSourceClearance) {
        self.caseID = caseID; self.prefix = prefix; self.suffix = suffix; self.replyTokens = replyTokens
        self.ttl = ttl; self.effort = effort; self.purpose = purpose; self.clearance = clearance
    }
}
