//
//  ContextPrefixGenerator.swift
//  Kalsmritikosh
//
//  G2-3 — per-chunk contextual retrieval. Produces a one-sentence
//  context prefix for each chunk describing the chunk's role inside
//  the parent document. The prefix is prepended ONLY at embed time
//  (see IngestCoordinator's embed block); display, FTS, citations,
//  and the stored chunk.text are unchanged.
//
//  Anthropic's contextual-retrieval write-up shows this opens the
//  vector-similarity gap between an on-target chunk and its
//  off-topic neighbors. The Gate-1 baseline saw 6 candidates within
//  0.018 of each other on L1 ("Who is the project owner?"); prefixing
//  each chunk with one sentence of doc context typically widens that
//  gap to ≥ 0.02, restoring decisive ranking.
//
//  Two implementations:
//   - `HeuristicContextPrefixGenerator`: synchronous, no LLM. Combines
//     filename + email subject (if any) + first non-trivial chunk
//     line. Always available; used as fallback when the LLM provider
//     is missing or times out.
//   - `LLMContextPrefixGenerator`: calls `CapabilitySpec.reasoning`
//     with a per-chunk timeout. Falls back to the heuristic on
//     timeout/error so ingest never hangs on a slow provider.
//

import Foundation
import OSLog

public nonisolated struct ContextPrefixRequest: Sendable {
    public let chunkText: String
    public let chunkOrdinal: Int
    public let totalChunks: Int
    public let filename: String
    public let documentOpening: String

    public init(
        chunkText: String,
        chunkOrdinal: Int,
        totalChunks: Int,
        filename: String,
        documentOpening: String
    ) {
        self.chunkText = chunkText
        self.chunkOrdinal = chunkOrdinal
        self.totalChunks = totalChunks
        self.filename = filename
        self.documentOpening = documentOpening
    }
}

/// Result of a single prefix-generation call. `source` records which
/// generator path produced the bytes so the persisted row can be
/// inspected later (e.g. "did the LLM actually run on this chunk, or
/// did we fall through to no-prefix?") without re-running the
/// generator.
///
/// Note: there is intentionally NO heuristic-fallback path inside
/// `LLMContextPrefixGenerator`. Per the project's quality-or-nothing
/// rule, the LLM either produces a prefix or no prefix is written —
/// we don't silently substitute heuristic noise into the embedding.
public nonisolated struct ContextPrefixResult: Sendable, Equatable {
    public static let sourceLLM = "llm"
    public static let sourceHeuristic = "heuristic"

    public let text: String
    public let source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

public protocol ContextPrefixGenerator: Sendable {
    /// Returns a one-sentence prefix describing `request.chunkText`'s
    /// role within its parent document plus a `source` label. Returns
    /// nil to indicate "no useful prefix" (callers leave both
    /// context_prefix AND context_prefix_source NULL).
    func prefix(for request: ContextPrefixRequest) async -> ContextPrefixResult?
}

// MARK: - Heuristic

public struct HeuristicContextPrefixGenerator: ContextPrefixGenerator {
    public init() {}

    /// Synchronous helper — useful when an LLM generator wants to call
    /// the heuristic as a fallback without the actor-hop overhead.
    public nonisolated func heuristicText(for request: ContextPrefixRequest) -> String? {
        var parts: [String] = []
        if !request.filename.isEmpty {
            parts.append("In \(request.filename)")
        }
        let opening = request.documentOpening
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !opening.isEmpty {
            parts.append("(\(String(opening.prefix(80))))")
        }
        if request.totalChunks > 1 {
            parts.append(", section \(request.chunkOrdinal + 1) of \(request.totalChunks)")
        }
        let prefix = parts.joined()
        return prefix.isEmpty ? nil : prefix
    }

    public func prefix(for request: ContextPrefixRequest) async -> ContextPrefixResult? {
        guard let text = heuristicText(for: request) else { return nil }
        return ContextPrefixResult(
            text: text,
            source: ContextPrefixResult.sourceHeuristic
        )
    }
}

// MARK: - LLM-backed

public actor LLMContextPrefixGenerator: ContextPrefixGenerator {
    private let capabilities: CapabilityRegistry
    /// Initial per-attempt timeout in milliseconds. The first attempt
    /// runs with this budget; each retry doubles, capped at `maxTimeoutMs`.
    private let initialTimeoutMs: UInt64
    /// Hard upper bound on a single attempt's timeout. The doubling
    /// stops here — beyond this we give up rather than let a single
    /// chunk consume unbounded ingest time.
    private let maxTimeoutMs: UInt64
    /// Maximum number of attempts per chunk. Counts the first try.
    /// `maxAttempts=3` with `initial=8s, max=32s` gives 8s, 16s, 32s
    /// across three tries — total worst case 56s per chunk.
    private let maxAttempts: Int

    public init(
        capabilities: CapabilityRegistry,
        initialTimeoutMs: UInt64 = 8_000,
        maxTimeoutMs: UInt64 = 32_000,
        maxAttempts: Int = 3
    ) {
        self.capabilities = capabilities
        self.initialTimeoutMs = initialTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Backward-compat constructor — keeps existing call sites that
    /// supply a single `timeoutMilliseconds:` working. Sets the same
    /// value for initial AND max with 1 attempt (no escalation).
    public init(
        capabilities: CapabilityRegistry,
        timeoutMilliseconds: UInt64
    ) {
        self.capabilities = capabilities
        self.initialTimeoutMs = timeoutMilliseconds
        self.maxTimeoutMs = timeoutMilliseconds
        self.maxAttempts = 1
    }

    public func prefix(for request: ContextPrefixRequest) async -> ContextPrefixResult? {
        // Resolve a reasoning provider. NO fallback: if none resolves
        // or it isn't available, this chunk gets no prefix.
        let spec = CapabilitySpec.reasoning(
            contextTokens: 1_500,
            purpose: "ingest.contextPrefix"
        )
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            AtlasLog.knowledge.info("contextPrefix: no reasoning provider available; chunk left without prefix")
            return nil
        }

        let userPrompt = buildPrompt(request: request)
        let options = GenerationOptions(
            maxTokens: 80,
            temperature: 0.0,
            systemPrompt: "You write a single sentence that locates a passage within its document. No preamble, no quotes. Output ONE sentence, max 25 words."
        )

        // Incremental retry: try with the initial budget; on timeout,
        // double it (capped at maxTimeoutMs) and try again, up to
        // maxAttempts. A real provider error (non-timeout) breaks
        // the loop immediately — errors are signal, retry won't help.
        var attemptTimeout = initialTimeoutMs
        for attempt in 1...maxAttempts {
            let (response, timedOut) = await runOnce(
                provider: provider,
                prompt: userPrompt,
                options: options,
                timeoutMs: attemptTimeout
            )
            if let raw = response {
                let cleaned = clean(raw)
                if !cleaned.isEmpty {
                    if attempt > 1 {
                        AtlasLog.knowledge.info("contextPrefix: provider \(provider.id, privacy: .public) recovered on attempt \(attempt, privacy: .public) with \(attemptTimeout, privacy: .public)ms")
                    }
                    await LLMCallCounters.shared.recordCall(purpose: "contextPrefix")
                    // Healthy — clear any accrued failure/cooldown.
                    await capabilities.reportOutcome(providerID: provider.id, success: true)
                    return ContextPrefixResult(
                        text: cleaned,
                        source: ContextPrefixResult.sourceLLM
                    )
                }
                // Non-empty raw but cleaned was empty — likely a
                // refusal / weird formatting. Don't retry; treat as
                // a real failure. Provider still responded, so not a
                // health failure.
                return nil
            }
            if !timedOut {
                // Provider returned a real error (not a timeout).
                // Retrying won't change the answer — count it against
                // the provider's health so a hard-down provider cools.
                await capabilities.reportOutcome(providerID: provider.id, success: false)
                return nil
            }
            // Timeout — escalate and try again, unless we hit max.
            await LLMCallCounters.shared.recordTimeout()
            if attempt >= maxAttempts { break }
            attemptTimeout = min(attemptTimeout * 2, maxTimeoutMs)
        }
        AtlasLog.knowledge.info("contextPrefix: provider \(provider.id, privacy: .public) exhausted \(self.maxAttempts, privacy: .public) attempts (final \(attemptTimeout, privacy: .public)ms); chunk left without prefix")
        // Sustained timeouts count against the provider's health so the
        // registry cools it down and later chunks skip it instantly
        // instead of each paying the full retry budget again.
        await capabilities.reportOutcome(providerID: provider.id, success: false)
        return nil
    }

    /// One bounded call. Returns (response, timedOut). `response` is
    /// nil when the call timed out OR errored; the timedOut flag
    /// distinguishes those so the retry loop knows whether to escalate.
    private func runOnce(
        provider: any ModelProvider,
        prompt: String,
        options: GenerationOptions,
        timeoutMs: UInt64
    ) async -> (String?, Bool) {
        enum Outcome: Sendable {
            case response(String)
            case timeout
            case error
        }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    let raw = try await provider.generate(prompt: prompt, options: options)
                    return .response(raw)
                } catch {
                    return .error
                }
            }
            group.addTask { [timeoutMs] in
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return .timeout
            }
            let first = await group.next() ?? .error
            group.cancelAll()
            return first
        }
        switch outcome {
        case .response(let s): return (s, false)
        case .timeout: return (nil, true)
        case .error: return (nil, false)
        }
    }

    private nonisolated func buildPrompt(request: ContextPrefixRequest) -> String {
        let docSnippet = String(request.documentOpening.prefix(900))
        let chunkSnippet = String(request.chunkText.prefix(700))
        return """
        Document: \(request.filename)
        Opening (first ~900 chars):
        \(docSnippet)

        Passage being summarized (section \(request.chunkOrdinal + 1) of \(request.totalChunks)):
        \(chunkSnippet)

        In one sentence, describe what this passage is about within the document above. Do not quote the passage; place it in context.
        """
    }

    private nonisolated func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(of: "\n", with: " ")
        // Hard cap so a model that ignored the system prompt can't
        // bloat the embed text. Embedders truncate anyway; this just
        // saves a few KB per chunk on disk.
        return String(stripped.prefix(280))
    }
}
