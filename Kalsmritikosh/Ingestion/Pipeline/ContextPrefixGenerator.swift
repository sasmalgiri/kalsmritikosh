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

public struct ContextPrefixRequest: Sendable {
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
/// path produced the bytes so the persisted row can be inspected later
/// ("how often did the LLM fall back to heuristic during this ingest?")
/// without re-running the generator.
public struct ContextPrefixResult: Sendable, Equatable {
    public static let sourceLLM = "llm"
    public static let sourceHeuristic = "heuristic"
    public static let sourceHeuristicFallback = "heuristic-fallback"

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
    private let timeoutMilliseconds: UInt64
    private let fallback: HeuristicContextPrefixGenerator

    public init(
        capabilities: CapabilityRegistry,
        timeoutMilliseconds: UInt64 = 2_000
    ) {
        self.capabilities = capabilities
        self.timeoutMilliseconds = timeoutMilliseconds
        self.fallback = HeuristicContextPrefixGenerator()
    }

    public func prefix(for request: ContextPrefixRequest) async -> ContextPrefixResult? {
        // Resolve a reasoning provider; fall back to heuristic if
        // none resolves or it isn't currently available.
        let spec = CapabilitySpec.reasoning(
            contextTokens: 1_500,
            purpose: "ingest.contextPrefix"
        )
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            return heuristicFallback(for: request)
        }

        let userPrompt = buildPrompt(request: request)
        let options = GenerationOptions(
            maxTokens: 80,
            temperature: 0.0,
            systemPrompt: "You write a single sentence that locates a passage within its document. No preamble, no quotes. Output ONE sentence, max 25 words."
        )

        // Per-chunk timeout so an unresponsive provider can't stall
        // ingest. On timeout / error / empty response we use the
        // heuristic, which always produces something.
        let llmResponse: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    return try await provider.generate(prompt: userPrompt, options: options)
                } catch {
                    AtlasLog.knowledge.info("contextPrefix: provider \(provider.id, privacy: .public) call failed; using heuristic")
                    return nil
                }
            }
            group.addTask { [timeoutMilliseconds] in
                try? await Task.sleep(nanoseconds: timeoutMilliseconds * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let raw = llmResponse {
            let cleaned = clean(raw)
            if !cleaned.isEmpty {
                return ContextPrefixResult(
                    text: cleaned,
                    source: ContextPrefixResult.sourceLLM
                )
            }
        }
        return heuristicFallback(for: request)
    }

    /// Wrap heuristic output with the "heuristic-fallback" source
    /// label so chunk rows persist a distinct marker from the case
    /// where the heuristic generator was wired directly.
    private nonisolated func heuristicFallback(for request: ContextPrefixRequest) -> ContextPrefixResult? {
        guard let text = fallback.heuristicText(for: request) else { return nil }
        return ContextPrefixResult(
            text: text,
            source: ContextPrefixResult.sourceHeuristicFallback
        )
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
